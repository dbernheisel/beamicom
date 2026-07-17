defmodule Beamicom.NES.PPU do
  @moduledoc """
  2C02 PPU — Phase A: memory + register interface (spec §5.2 item 2, "where most
  bugs live"). Holds the internal address space ($0000-$3FFF): CHR pattern tables
  from the cartridge, 2KB nametable VRAM (mirrored per cartridge wiring), 32-byte
  palette RAM, and 256-byte OAM. Implements the $2000-$2007 register semantics:
  the `v`/`t`/`x`/`w` loopy registers, the buffered $2007 read, palette immediacy
  and mirroring, and OAM access via $2003/$2004.

  Rendering (background pipeline, sprites) and dot timing land in later phases.

  ## Sources
    * NESdev Wiki — PPU registers & the loopy v/t/x/w scroll registers:
      https://www.nesdev.org/wiki/PPU_scrolling
    * NESdev Wiki — PPU memory map & nametable mirroring:
      https://www.nesdev.org/wiki/PPU_memory_map, .../Mirroring
    * NESdev Wiki — PPU palettes (mirroring of $3F10/$14/$18/$1C):
      https://www.nesdev.org/wiki/PPU_palettes
    * Validation targets: blargg vram_access / palette_ram / sprite_ram.
  """

  import Bitwise

  # Bit-reversed byte lookup (input is always 0..255), computed at compile time:
  # turns the 8-iteration reduce in horizontal sprite flips into one `elem/2`.
  @rev 0..255
       |> Enum.map(fn b ->
         <<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1>> = <<b>>
         <<r>> = <<b0::1, b1::1, b2::1, b3::1, b4::1, b5::1, b6::1, b7::1>>
         r
       end)
       |> List.to_tuple()

  @compile {:inline,
            sel: 2,
            bg_on?: 1,
            sprites_on?: 1,
            clipped?: 2,
            palette_addr: 1,
            nt_bank: 2,
            nametable: 2,
            table_key: 1,
            vram_step: 1,
            split_region?: 3,
            split_active?: 1,
            bg_banks: 1,
            next_stop: 1,
            scanline_len: 1}

  defstruct ctrl: 0,
            mask: 0,
            status: 0,
            oam_addr: 0,
            v: 0,
            t: 0,
            x: 0,
            w: 0,
            buffer: 0,
            vram: <<0::size(0x800 * 8)>>,
            palette: %{},
            oam: <<0::size(256 * 8)>>,
            chr: <<>>,
            chr_ram: %{},
            chr_banks: {0, 0x400, 0x800, 0xC00, 0x1000, 0x1400, 0x1800, 0x1C00},
            # MMC5 uses a separate background CHR bank set in 8x16 sprite mode;
            # for every other mapper this mirrors chr_banks.
            bg_chr_banks: {0, 0x400, 0x800, 0xC00, 0x1000, 0x1400, 0x1800, 0x1C00},
            # MMC2/4 CHR latch: nil, or %{l0,l1 (:fd|:fe), fd0,fe0,fd1,fe1 (4KB offsets)}.
            chr_latch: nil,
            # MMC5 ExRAM + nametable control (nil nt_source = standard mirroring).
            exram: %{},
            exram_mode: 0,
            nt_source: nil,
            fill_tile: 0,
            fill_attr: 0,
            ext_chr_hi: 0,
            ext_latch: 0,
            # MMC5 vertical split ($5200-$5202): a column range rendered from ExRAM
            # with its own vertical scroll and 4KB CHR bank.
            split_en: false,
            split_side: 0,
            split_tile: 0,
            split_scroll: 0,
            split_chr: 0,
            mirroring: :horizontal,
            scanline: 0,
            dot: 0,
            frame: 0,
            nmi_suppress: false,
            # Background render pipeline (spec §5.2 item 1)
            nt_latch: 0,
            at_latch: 0,
            bg_lo_latch: 0,
            bg_hi_latch: 0,
            bg_lo: 0,
            bg_hi: 0,
            at_lo: 0,
            at_hi: 0,
            line_sprites: [],
            irq_ticks: 0,
            # Frame-synced rendered-scanline number captured at the per-scanline
            # IRQ tick, for the MMC5 scanline IRQ (reset to 0 at the pre-render line).
            irq_scanline: 0,
            fb: [],
            # Tile-row cache: the 33 fetched {nametable, attribute} pairs plus the
            # {v & $0FFF, nt_source} key they were fetched for. The 8 scanlines of a
            # tile row read the same nametable/attribute bytes (only the fine-Y
            # pattern differs), so a matching key lets a scanline reuse them and
            # refetch just the pattern. The key changes whenever v/scroll/nametable
            # ($2000/$2005/$2006/$2007) or mirroring ($5105) changes, so it is
            # self-invalidating; only used on the common path (no split / ext-attr).
            tile_key: nil,
            tile_nt_at: nil,
            frame_ready: nil

  @doc "Build a PPU over the cartridge's CHR data and nametable mirroring."
  def new(chr, mirroring), do: %__MODULE__{chr: chr, mirroring: mirroring}

  # --- dot timing (spec §3): 341 dots/scanline, 262 scanlines/frame ---
  # Scanline 241 dot 1 raises vblank; the pre-render line 261 dot 1 clears
  # vblank + sprite-0 + overflow. The NMI line is the level (vblank AND
  # PPUCTRL bit 7); the CPU polls it per cycle and detects the edge.

  @doc """
  Advance the PPU by `dots`.

  Rather than touch the struct on every one of the ~341 dots per scanline, we
  jump straight to the next dot where something actually happens — VBL set/clear,
  the once-per-line render, the scroll-register copies, the MMC IRQ clock — and
  only bump the dot counter in between. The (scanline, dot, frame, VBL) state
  after any `run/2` is identical to a dot-by-dot walk, so CPU/PPU alignment and
  NMI timing are unchanged; it's just far fewer struct updates.
  """
  def run(ppu, 0), do: ppu

  def run(ppu, dots) do
    d = ppu.dot
    stop = min(next_stop(d), scanline_len(ppu))

    # Common case: the whole span stays before the next event — just move the dot.
    if d + dots < stop do
      %{ppu | dot: d + dots}
    else
      run(commit(ppu, stop), dots - (stop - d))
    end
  end

  @doc "Current NMI output line level: vblank flag set AND NMI enabled."
  def nmi_line?(ppu), do: (ppu.status &&& 0x80) != 0 and (ppu.ctrl &&& 0x80) != 0

  # Next dot (this scanline) where an event fires; landing on the scanline length
  # means "run off the end and wrap to the next scanline".
  defp next_stop(dot) when dot < 1, do: 1
  defp next_stop(dot) when dot < 257, do: 257
  defp next_stop(dot) when dot < 260, do: 260
  defp next_stop(dot) when dot < 280, do: 280
  defp next_stop(_dot), do: 341

  # 341 dots/scanline, except the pre-render line on odd frames with rendering on
  # is one short (the (261,339)→(0,0) dot skip, spec §5.2 item 5).
  defp scanline_len(%{scanline: 261, frame: f, mask: m})
       when (f &&& 1) == 1 and (m &&& 0x18) != 0,
       do: 340

  defp scanline_len(_ppu), do: 341

  # Land exactly on `stop` and fire its event; `stop` at the scanline length wraps
  # to dot 0 of the next scanline (pre-render → next frame).
  defp commit(%{scanline: 261, frame: f} = ppu, 340),
    do: fire_event(%{ppu | scanline: 0, dot: 0, frame: f + 1})

  defp commit(%{scanline: 261, frame: f} = ppu, 341),
    do: fire_event(%{ppu | scanline: 0, dot: 0, frame: f + 1})

  defp commit(%{scanline: s} = ppu, 341), do: fire_event(%{ppu | scanline: s + 1, dot: 0})
  defp commit(ppu, stop), do: fire_event(%{ppu | dot: stop})

  # Handle whatever is due at the PPU's current (scanline, dot). Event dots are
  # disjoint, so at most one fires.
  defp fire_event(%{scanline: s, dot: d} = ppu) do
    rendering = (ppu.mask &&& 0x18) != 0

    cond do
      d == 257 and s <= 239 ->
        render_scanline(ppu)

      d == 257 and s == 261 and rendering ->
        copy_hori(ppu)

      d == 280 and s == 261 and rendering ->
        copy_vert(ppu)

      # Per-scanline IRQ tick. MMC3 counts these; MMC5 uses the frame-synced
      # scanline number (visible line s → counter s+1; pre-render resets to 0).
      d == 260 and rendering and s <= 239 ->
        %{ppu | irq_ticks: ppu.irq_ticks + 1, irq_scanline: s + 1}

      d == 260 and rendering and s == 261 ->
        %{ppu | irq_ticks: ppu.irq_ticks + 1, irq_scanline: 0}

      d == 0 and s == 240 ->
        finish_frame(ppu)

      d == 1 and s == 241 ->
        %{ppu | status: ppu.status ||| 0x80}

      d == 1 and s == 261 ->
        %{ppu | status: ppu.status &&& bxor(0xFF, 0xE0)}

      true ->
        ppu
    end
  end

  # --- background render (spec §5.2 item 1, line-by-line timing) ---
  # A whole visible scanline is produced in one pass: fetch its background tiles
  # through the same MMC5-aware fetch path the per-dot pipeline used (so split /
  # extended-attribute / MMC2-4 CHR-latch behaviour is unchanged), composite
  # sprites over them, then advance the scroll registers (dots 256/257).

  defp render_scanline(ppu) do
    if (ppu.mask &&& 0x18) == 0 do
      # Rendering off: the line is the backdrop and the scroll registers freeze.
      %{ppu | fb: [<<0::size(256 * 8)>> | ppu.fb]}
    else
      line_v = ppu.v
      {tiles, blank?, ppu} = fetch_line_tiles(ppu, line_v)
      ppu = eval_sprites(ppu)
      {line, ppu} = compose_line(ppu, tiles, ppu.x, blank?)
      ppu = %{ppu | fb: [line | ppu.fb], v: line_v}
      copy_hori(inc_vert(ppu))
    end
  end

  # Fetch the 33 background tiles that cover the 256 visible pixels plus the fine-x
  # slack, walking coarse X with inc_hori. Each entry is {pattern-lo, pattern-hi,
  # 2-bit palette}; `blank?` is true when every tile's pattern is empty (so the
  # whole background reduces to the backdrop). The working `v` is discarded by the
  # caller (restored to line_v).
  defp fetch_line_tiles(ppu, line_v) do
    key = {line_v &&& 0x0FFF, ppu.nt_source}
    ppu = %{ppu | v: line_v}

    # Reuse the tile row's nametable/attribute fetches when the key matches and
    # we're on the common path (no vertical split, no extended-attribute mode);
    # only the fine-Y-dependent pattern is re-fetched below.
    if ppu.tile_nt_at != nil and ppu.tile_key == key and not ppu.split_en and
         ppu.exram_mode != 1 do
      # This path is guaranteed non-split, non-extended-attribute, so the pattern
      # fetch is the plain `true` branch of `fetch_bg_planes`. Without an MMC2/4
      # CHR latch (the common case) nothing on `ppu` changes across the 33 tiles —
      # fine-Y, the CHR table bit, banks and `chr` are all line-constants — so run
      # a tight pure loop with no per-tile 50-key struct rebuild.
      {acc, blank?, ppu} =
        if ppu.chr_latch == nil do
          fine_y = ppu.v >>> 12 &&& 0x07
          tbl = (ppu.ctrl &&& 0x10) <<< 8

          {a, b} =
            bg_cached_fast(
              0,
              ppu.tile_nt_at,
              fine_y,
              tbl,
              bg_banks(ppu),
              ppu.chr,
              ppu.chr_ram,
              [],
              true
            )

          {a, b, ppu}
        else
          fetch_cached(0, ppu, ppu.tile_nt_at, [], true)
        end

      {acc |> Enum.reverse() |> List.to_tuple(), blank?, ppu}
    else
      {acc, ntat, blank?, ppu} = fetch_full(0, ppu, [], [], true)
      tiles = acc |> Enum.reverse() |> List.to_tuple()

      ppu =
        if not ppu.split_en and ppu.exram_mode != 1,
          do: %{ppu | tile_key: key, tile_nt_at: ntat |> Enum.reverse() |> List.to_tuple()},
          else: %{ppu | tile_key: nil}

      {tiles, blank?, ppu}
    end
  end

  # Full fetch: nametable + attribute + pattern per tile, walking coarse X. Also
  # collects the {nt, at} pairs so the rest of the tile row can reuse them.
  defp fetch_full(33, ppu, acc, ntat, blank?), do: {acc, ntat, blank?, ppu}

  defp fetch_full(i, ppu, acc, ntat, blank?) do
    ppu = ppu |> fetch_nt() |> fetch_at() |> fetch_bg_planes()
    tile = {ppu.bg_lo_latch, ppu.bg_hi_latch, ppu.at_latch}
    blank? = blank? and ppu.bg_lo_latch == 0 and ppu.bg_hi_latch == 0
    fetch_full(i + 1, inc_hori(ppu), [tile | acc], [{ppu.nt_latch, ppu.at_latch} | ntat], blank?)
  end

  # Cached fetch: reuse the row's {nt, at} and re-fetch only the pattern for this
  # scanline's fine Y (no nametable/attribute read, no coarse-X walk).
  defp fetch_cached(33, ppu, _ntat, acc, blank?), do: {acc, blank?, ppu}

  defp fetch_cached(i, ppu, ntat, acc, blank?) do
    {nt, at} = elem(ntat, i)
    ppu = %{ppu | nt_latch: nt, at_latch: at} |> fetch_bg_planes()
    tile = {ppu.bg_lo_latch, ppu.bg_hi_latch, at}
    blank? = blank? and ppu.bg_lo_latch == 0 and ppu.bg_hi_latch == 0
    fetch_cached(i + 1, ppu, ntat, [tile | acc], blank?)
  end

  # Pure fast path of `fetch_cached` (no CHR latch): reuses the row's {nt, at} and
  # the line-constant fine-Y / CHR-table / banks / chr, so it computes all 33
  # tiles' pattern bytes without ever rebuilding the PPU struct. Mirrors the plain
  # `true` branch of `fetch_bg_planes/1` exactly.
  defp bg_cached_fast(33, _ntat, _fy, _tbl, _banks, _chr, _ram, acc, blank?), do: {acc, blank?}

  defp bg_cached_fast(i, ntat, fy, tbl, banks, chr, ram, acc, blank?) do
    {nt, at} = elem(ntat, i)
    addr = tbl ||| nt <<< 4 ||| fy
    off = elem(banks, addr >>> 10) + (addr &&& 0x03FF)

    {lo, hi} =
      if byte_size(chr) > 0,
        do: {:binary.at(chr, off), :binary.at(chr, off + 8)},
        else: {Map.get(ram, off, 0), Map.get(ram, off + 8, 0)}

    tile = {lo, hi, at}

    bg_cached_fast(
      i + 1,
      ntat,
      fy,
      tbl,
      banks,
      chr,
      ram,
      [tile | acc],
      blank? and lo == 0 and hi == 0
    )
  end

  # Composite one scanline's 256 pixels (background + sprite priority) into a
  # 256-byte binary of palette-RAM addresses. Sprites are rasterised once into a
  # per-column buffer (front-most opaque pixel wins), so compositing is an O(1)
  # lookup per pixel; sprite-0 hit is checked over just the ≤8 columns sprite 0
  # covers.
  defp compose_line(ppu, tiles, fine_x, blank?) do
    bg_on = bg_on?(ppu)
    buf = if sprites_on?(ppu), do: sprite_buffer(ppu.line_sprites), else: %{}

    clip? = (ppu.mask &&& 0x04) == 0
    bg_blank? = blank? or not bg_on

    line =
      cond do
        # No sprites and the background is entirely backdrop → 256 backdrop bytes.
        map_size(buf) == 0 and bg_blank? ->
          <<0::size(256 * 8)>>

        # Sprite-less line: compose the whole background at once, tile-batched
        # (decode 8 px per tile instead of per-pixel). This is the dominant cost
        # in background-heavy games (SMB3 overworld) where most lines have no
        # sprites; the ≤8 px/tile decode replaces 256 per-pixel `bg_at` calls.
        map_size(buf) == 0 ->
          bg_line(tiles, fine_x, ppu.mask)

        # Sprite line over a blank background (CV3's intro): every sprite pixel
        # wins over the all-backdrop line.
        bg_blank? ->
          overlay_sprites(<<0::size(256 * 8)>>, buf, clip?)

        # Sprite line over real background: overlay sprites onto the batched bg
        # line, touching only the columns a sprite covers.
        true ->
          overlay_sprites(bg_line(tiles, fine_x, ppu.mask), buf, clip?)
      end

    # Sprite-0 hit needs sprite 0 over an opaque background pixel — impossible with
    # no sprites or a blank background, so skip the scan in those cases.
    ppu =
      if bg_blank? or map_size(buf) == 0,
        do: ppu,
        else: sprite0_hit(ppu, buf, tiles, fine_x, bg_on)

    {line, ppu}
  end

  # Composite sprites onto a precomputed 256-byte background line by touching only
  # the columns a sprite actually covers (≤64), splicing the untouched background
  # runs between them — far cheaper than a 256-pixel Map-lookup walk. Front-most
  # opaque sprite wins unless a non-front sprite sits over an opaque bg pixel; the
  # left-8px sprite clip drops sprite columns 0..7.
  defp overlay_sprites(bg, buf, clip?) do
    cols = buf |> Map.keys() |> Enum.sort()
    cols = if clip?, do: Enum.drop_while(cols, &(&1 < 8)), else: cols
    overlay(bg, buf, cols, 0, <<>>)
  end

  defp overlay(bg, _buf, [], cursor, acc),
    do: <<acc::binary, binary_part(bg, cursor, 256 - cursor)::binary>>

  defp overlay(bg, buf, [c | rest], cursor, acc) do
    {sp_addr, front?, _z} = Map.fetch!(buf, c)
    bg_addr = :binary.at(bg, c)
    win = if bg_addr != 0 and not front?, do: bg_addr, else: sp_addr

    overlay(
      bg,
      buf,
      rest,
      c + 1,
      <<acc::binary, binary_part(bg, cursor, c - cursor)::binary, win>>
    )
  end

  # Per-pixel background palette-address (0 = transparent backdrop), used on sprite
  # lines and for the sprite-0-hit check. fine-x scrolls the source; left-8px clip.
  defp bg_at(_tiles, _fine_x, _c, false, _mask), do: 0

  defp bg_at(tiles, fine_x, c, true, mask) do
    if c < 8 and (mask &&& 0x02) == 0 do
      0
    else
      e = fine_x + c
      {lo, hi, attr} = elem(tiles, e >>> 3)
      bit = 7 - (e &&& 7)
      pattern = sel(hi, bit) <<< 1 ||| sel(lo, bit)
      if pattern == 0, do: 0, else: attr <<< 2 ||| pattern
    end
  end

  # Background line as 256 palette-address bytes. Decodes each of the 33 fetched
  # tiles into 8 bytes at once (blank tiles → 8 zero bytes, the common case), then
  # slices out the fine-x window and applies the left-8px background clip.
  defp bg_line(tiles, fine_x, mask) do
    line = binary_part(bg_full(tiles, 0, <<>>), fine_x, 256)

    if (mask &&& 0x02) == 0,
      do: <<0::size(8 * 8), binary_part(line, 8, 248)::binary>>,
      else: line
  end

  defp bg_full(_tiles, 33, acc), do: acc

  defp bg_full(tiles, i, acc) do
    {lo, hi, attr} = elem(tiles, i)
    bg_full(tiles, i + 1, <<acc::binary, tile_bytes(lo, hi, attr)::binary>>)
  end

  # One tile → its 8 palette-address bytes (leftmost pixel first = bit 7). Blank
  # patterns are by far the most common tile, so short-circuit them.
  defp tile_bytes(0, 0, _attr), do: <<0, 0, 0, 0, 0, 0, 0, 0>>

  defp tile_bytes(lo, hi, attr) do
    ab = attr <<< 2

    <<px(lo, hi, ab, 7), px(lo, hi, ab, 6), px(lo, hi, ab, 5), px(lo, hi, ab, 4),
      px(lo, hi, ab, 3), px(lo, hi, ab, 2), px(lo, hi, ab, 1), px(lo, hi, ab, 0)>>
  end

  defp px(lo, hi, ab, b) do
    pattern = (hi >>> b &&& 1) <<< 1 ||| (lo >>> b &&& 1)
    if pattern == 0, do: 0, else: ab ||| pattern
  end

  # Sprite-0 hit: sprite 0's front-most opaque pixel (buffer zero? flag) over an
  # opaque background pixel, outside the clips and not at column 255.
  defp sprite0_hit(ppu, buf, tiles, fine_x, bg_on) do
    hit? =
      Enum.any?(buf, fn
        {c, {_addr, _front?, true}} ->
          c != 255 and not clipped?(ppu, c) and bg_at(tiles, fine_x, c, bg_on, ppu.mask) != 0

        _ ->
          false
      end)

    if hit?, do: %{ppu | status: ppu.status ||| 0x40}, else: ppu
  end

  # Rasterise the (≤8) line sprites into a column => {addr, front?, sprite-0?} map.
  # Sprites are in OAM order (front-most first), so the first writer of a column
  # wins — matching the front-most-opaque-pixel priority of a per-pixel scan.
  defp sprite_buffer(sprites) do
    Enum.reduce(sprites, %{}, fn sp, buf ->
      Enum.reduce(0..7, buf, fn col, buf ->
        x = sp.x + col
        bit = 7 - col
        pat = sel(sp.hi, bit) <<< 1 ||| sel(sp.lo, bit)

        if x <= 255 and pat != 0 and not Map.has_key?(buf, x) do
          addr = 0x10 ||| (sp.attr &&& 0x03) <<< 2 ||| pat
          Map.put(buf, x, {addr, (sp.attr &&& 0x20) == 0, sp.index == 0})
        else
          buf
        end
      end)
    end)
  end

  defp bg_on?(ppu), do: (ppu.mask &&& 0x08) != 0
  defp sprites_on?(ppu), do: (ppu.mask &&& 0x10) != 0

  # Left-8px clip suppresses sprite-0 hit when either the background (bit 1) or
  # sprite (bit 2) clip is active.
  defp clipped?(ppu, x), do: x < 8 and ((ppu.mask &&& 0x02) == 0 or (ppu.mask &&& 0x04) == 0)

  defp sel(reg, bit), do: reg >>> bit &&& 1

  # --- sprite evaluation (spec §5.2 item 4) ---
  # Scan the 64 OAM entries for those on this scanline, keeping the first 8 (OAM
  # order = priority). A 9th sets the overflow flag. Sprite Y is stored one line
  # early, so a sprite at OAM Y renders on scanlines Y+1..Y+height.

  defp eval_sprites(ppu) do
    height = if (ppu.ctrl &&& 0x20) != 0, do: 16, else: 8
    {sprites, count} = scan_oam(ppu.oam, 0, ppu, height, [], 0)
    status = if count > 8, do: ppu.status ||| 0x20, else: ppu.status
    %{ppu | line_sprites: Enum.reverse(sprites), status: status}
  end

  # Walk the 256-byte OAM binary four bytes (one sprite) at a time, keeping the
  # first 8 that fall on this scanline (OAM order = priority); a 9th sets overflow.
  defp scan_oam(<<>>, _i, _ppu, _height, acc, count), do: {acc, count}

  defp scan_oam(<<y, tile, attr, x, rest::binary>>, i, ppu, height, acc, count) do
    row = ppu.scanline - y - 1

    cond do
      row < 0 or row >= height ->
        scan_oam(rest, i + 1, ppu, height, acc, count)

      count < 8 ->
        sprite = build_sprite(ppu, i, tile, attr, x, row, height)
        scan_oam(rest, i + 1, ppu, height, [sprite | acc], count + 1)

      true ->
        scan_oam(rest, i + 1, ppu, height, acc, count + 1)
    end
  end

  defp build_sprite(ppu, i, tile, attr, x, row, height) do
    row = if (attr &&& 0x80) != 0, do: height - 1 - row, else: row
    {addr, row} = sprite_pattern_addr(ppu, tile, row, height)
    lo = read(ppu, addr ||| row)
    hi = read(ppu, addr ||| row + 8)
    {lo, hi} = if (attr &&& 0x40) != 0, do: {reverse_byte(lo), reverse_byte(hi)}, else: {lo, hi}
    %{index: i, x: x, attr: attr, lo: lo, hi: hi}
  end

  # 8x8: pattern table from PPUCTRL bit 3. 8x16: table from tile bit 0, tile pair
  # from tile & $FE, and rows 8..15 use the second tile.
  defp sprite_pattern_addr(ppu, tile, row, 8),
    do: {(ppu.ctrl &&& 0x08) <<< 9 ||| tile <<< 4, row}

  defp sprite_pattern_addr(_ppu, tile, row, 16) do
    bank = (tile &&& 0x01) <<< 12
    tile = tile &&& 0xFE
    {tile, row} = if row >= 8, do: {tile + 1, row - 8}, else: {tile, row}
    {bank ||| tile <<< 4, row}
  end

  defp reverse_byte(b), do: elem(@rev, b)

  defp fetch_nt(ppu) do
    cond do
      # Vertical split: tiles come from ExRAM at the split's own vertical position.
      split_active?(ppu) ->
        {cy, _} = split_yc(ppu)
        %{ppu | nt_latch: Map.get(ppu.exram, cy * 32 + (ppu.v &&& 0x1F), 0), ext_latch: 0}

      # Extended-attribute mode ($5104=1): this tile's ExRAM byte gives its CHR
      # bank (bits 0-5) and palette (bits 6-7).
      ppu.exram_mode == 1 ->
        nt = nt_read(ppu, 0x2000 ||| (ppu.v &&& 0x0FFF))
        %{ppu | nt_latch: nt, ext_latch: Map.get(ppu.exram, ppu.v &&& 0x03FF, 0)}

      true ->
        %{ppu | nt_latch: nt_read(ppu, 0x2000 ||| (ppu.v &&& 0x0FFF)), ext_latch: 0}
    end
  end

  # The vertical split replaces a contiguous column range with ExRAM-sourced tiles.
  # Fast-out on the common case (split disabled) via a guard, so the per-tile
  # fetch path never evaluates the region check when there's no vertical split.
  defp split_active?(%{split_en: false}), do: false

  defp split_active?(ppu),
    do: split_region?(ppu.split_side, ppu.split_tile, ppu.v &&& 0x1F)

  defp split_region?(0, tile, col), do: col < tile
  defp split_region?(_side, tile, col), do: col >= tile

  defp split_yc(ppu) do
    row = rem(ppu.scanline + ppu.split_scroll, 240)
    {div(row, 8), rem(row, 8)}
  end

  defp fetch_at(ppu) do
    cond do
      split_active?(ppu) ->
        {cy, _} = split_yc(ppu)
        cx = ppu.v &&& 0x1F
        byte = Map.get(ppu.exram, 0x3C0 + (cy >>> 2) * 8 + (cx >>> 2), 0)
        %{ppu | at_latch: byte >>> ((cy &&& 2) <<< 1 ||| (cx &&& 2)) &&& 0x03}

      ppu.exram_mode == 1 ->
        %{ppu | at_latch: ppu.ext_latch >>> 6 &&& 0x03}

      true ->
        v = ppu.v
        addr = 0x23C0 ||| (v &&& 0x0C00) ||| (v >>> 4 &&& 0x38) ||| (v >>> 2 &&& 0x07)
        quadrant = (v >>> 4 &&& 0x04) ||| (v &&& 0x02)
        %{ppu | at_latch: nt_read(ppu, addr) >>> quadrant &&& 0x03}
    end
  end

  # Fetch both pattern planes (lo/hi) of the current bg tile in one pass: the plane
  # addresses differ only by 8 and live in the same 1KB CHR bank, so the bank
  # offset is computed once instead of per-plane. The MMC2/4 CHR latch is still
  # applied for both fetched addresses (no-op when there's no latch).
  defp fetch_bg_planes(ppu) do
    fine_y = ppu.v >>> 12 &&& 0x07

    {lo_addr, lo, hi_addr, hi} =
      cond do
        split_active?(ppu) ->
          {_, fy} = split_yc(ppu)
          base = ppu.split_chr * 0x1000 + (ppu.nt_latch <<< 4) + fy
          {base, chr_flat(ppu, base), base + 8, chr_flat(ppu, base + 8)}

        ppu.exram_mode == 1 ->
          bank = (ppu.ext_latch &&& 0x3F) ||| ppu.ext_chr_hi <<< 6
          base = bank * 0x1000 + (ppu.nt_latch <<< 4) + fine_y
          {base, chr_flat(ppu, base), base + 8, chr_flat(ppu, base + 8)}

        true ->
          addr = (ppu.ctrl &&& 0x10) <<< 8 ||| ppu.nt_latch <<< 4 ||| fine_y
          banks = bg_banks(ppu)
          off = elem(banks, addr >>> 10) + (addr &&& 0x03FF)

          {lo, hi} =
            if byte_size(ppu.chr) > 0,
              do: {:binary.at(ppu.chr, off), :binary.at(ppu.chr, off + 8)},
              else: {Map.get(ppu.chr_ram, off, 0), Map.get(ppu.chr_ram, off + 8, 0)}

          {addr, lo, addr + 8, hi}
      end

    %{ppu | bg_lo_latch: lo, bg_hi_latch: hi}
    |> apply_chr_latch(lo_addr)
    |> apply_chr_latch(hi_addr)
  end

  # Read a CHR byte at a flat byte offset (extended-attribute mode).
  defp chr_flat(ppu, off) do
    size = if byte_size(ppu.chr) > 0, do: byte_size(ppu.chr), else: 0x2000
    off = rem(off, size)
    if byte_size(ppu.chr) > 0, do: :binary.at(ppu.chr, off), else: Map.get(ppu.chr_ram, off, 0)
  end

  # MMC2/4: fetching tile $FD/$FE ($xFD8/$xFE8) flips that pattern table's latch,
  # reselecting its 4KB CHR bank. ponytail: driven by background fetches only;
  # sprite-fetch latching is unmodeled (rare, and untestable here without a ROM).
  defp apply_chr_latch(%{chr_latch: nil} = ppu, _addr), do: ppu

  defp apply_chr_latch(ppu, addr) do
    table = addr >>> 12 &&& 1
    cl = ppu.chr_latch

    cl =
      case addr &&& 0x0FF8 do
        0x0FD8 -> Map.put(cl, table_key(table), :fd)
        0x0FE8 -> Map.put(cl, table_key(table), :fe)
        _ -> cl
      end

    if cl == ppu.chr_latch, do: ppu, else: relatch(%{ppu | chr_latch: cl})
  end

  defp table_key(0), do: :l0
  defp table_key(1), do: :l1

  @doc "Recompute chr_banks from the MMC2/4 latches (each table's 4KB bank → 4 1KB windows)."
  def relatch(%{chr_latch: cl} = ppu) do
    o0 = if cl.l0 == :fd, do: cl.fd0, else: cl.fe0
    o1 = if cl.l1 == :fd, do: cl.fd1, else: cl.fe1

    banks =
      {o0, o0 + 0x400, o0 + 0x800, o0 + 0xC00, o1, o1 + 0x400, o1 + 0x800, o1 + 0xC00}

    %{ppu | chr_banks: banks, bg_chr_banks: banks}
  end

  # Coarse-X increment with horizontal nametable wrap.
  defp inc_hori(ppu) do
    v = ppu.v

    v =
      if (v &&& 0x001F) == 31,
        do: bxor(v &&& bxor(0x7FFF, 0x001F), 0x0400),
        else: v + 1

    %{ppu | v: v &&& 0x7FFF}
  end

  # Fine/coarse-Y increment with vertical nametable wrap at row 29.
  defp inc_vert(ppu) do
    v = ppu.v

    v =
      if (v &&& 0x7000) != 0x7000 do
        v + 0x1000
      else
        v = v &&& bxor(0x7FFF, 0x7000)
        y = (v &&& 0x03E0) >>> 5

        {y, v} =
          cond do
            y == 29 -> {0, bxor(v, 0x0800)}
            y == 31 -> {0, v}
            true -> {y + 1, v}
          end

        (v &&& bxor(0x7FFF, 0x03E0)) ||| y <<< 5
      end

    %{ppu | v: v &&& 0x7FFF}
  end

  # Reload horizontal (dot 257) / vertical (dots 280-304) scroll bits from t. With
  # no mid-frame scroll change v already matches, so skip the rebuild (once/line).
  defp copy_hori(ppu), do: copy_bits(ppu, 0x041F)
  defp copy_vert(ppu), do: copy_bits(ppu, 0x7BE0)

  defp copy_bits(%{v: v, t: t} = ppu, mask) do
    nv = (v &&& bxor(0x7FFF, mask)) ||| (t &&& mask)
    if nv == v, do: ppu, else: %{ppu | v: nv}
  end

  defp finish_frame(ppu) do
    # fb accumulates one 256-byte binary per visible scanline, newest first.
    pixels = ppu.fb |> Enum.reverse() |> IO.iodata_to_binary()
    palette = for i <- 0..31, into: <<>>, do: <<Map.get(ppu.palette, i, 0)>>

    frame = %Beamicom.NES.Framebuffer{
      number: ppu.frame,
      pixels: pixels,
      palette: palette,
      grayscale: (ppu.mask &&& 0x01) != 0,
      emphasis: {(ppu.mask &&& 0x20) != 0, (ppu.mask &&& 0x40) != 0, (ppu.mask &&& 0x80) != 0}
    }

    %{ppu | frame_ready: frame, fb: []}
  end

  # --- CPU-facing register interface ($2000-$2007, mirrored every 8) ---

  @doc "Read a PPU register. Returns {value, ppu} — reads have side effects."
  def read_register(ppu, addr), do: reg_read(ppu, 0x2000 + (addr &&& 7))

  # $2002 PPUSTATUS: top 3 bits are live; reading clears vblank and the w latch.
  # Race (spec §5.2 item 3): reading on the exact set dot (241,1) reads back as
  # clear and never sets the flag; reading within a few dots of the set
  # suppresses the NMI (the CPU cancels the just-latched interrupt).
  defp reg_read(ppu, 0x2002) do
    at_set = ppu.scanline == 241 and ppu.dot == 1
    near_set = ppu.scanline == 241 and ppu.dot in 1..3
    vbl = if at_set, do: 0, else: ppu.status &&& 0x80
    value = vbl ||| (ppu.status &&& 0x60) ||| (ppu.buffer &&& 0x1F)
    {value, %{ppu | status: ppu.status &&& bxor(0xFF, 0x80), w: 0, nmi_suppress: near_set}}
  end

  # $2004 OAMDATA: no address increment on read; attribute byte reads masked $E3.
  defp reg_read(ppu, 0x2004), do: {oam_read(ppu, ppu.oam_addr), ppu}

  # $2007 PPUDATA: palette reads are immediate; everything else is delayed one read.
  defp reg_read(ppu, 0x2007) do
    addr = ppu.v &&& 0x3FFF

    {value, buffer} =
      if addr >= 0x3F00 do
        {read(ppu, addr), read(ppu, addr - 0x1000)}
      else
        {ppu.buffer, read(ppu, addr)}
      end

    {value, %{ppu | buffer: buffer, v: ppu.v + vram_step(ppu) &&& 0x7FFF}}
  end

  defp reg_read(ppu, _open_bus), do: {ppu.buffer, ppu}

  @doc "Write a PPU register."
  def write_register(ppu, addr, value), do: reg_write(ppu, 0x2000 + (addr &&& 7), value &&& 0xFF)

  # $2000 PPUCTRL: also latches nametable-select into t bits 10-11.
  defp reg_write(ppu, 0x2000, v),
    do: %{ppu | ctrl: v, t: (ppu.t &&& 0x73FF) ||| (v &&& 0x03) <<< 10}

  defp reg_write(ppu, 0x2001, v), do: %{ppu | mask: v}
  defp reg_write(ppu, 0x2003, v), do: %{ppu | oam_addr: v}

  defp reg_write(ppu, 0x2004, v),
    do: %{oam_write(ppu, ppu.oam_addr, v) | oam_addr: ppu.oam_addr + 1 &&& 0xFF}

  # $2005 PPUSCROLL: first write sets coarse-X + fine-x, second sets Y.
  defp reg_write(%{w: 0} = ppu, 0x2005, v),
    do: %{ppu | t: (ppu.t &&& 0x7FE0) ||| v >>> 3, x: v &&& 0x07, w: 1}

  defp reg_write(%{w: 1} = ppu, 0x2005, v),
    do: %{ppu | t: (ppu.t &&& 0x0C1F) ||| (v &&& 0x07) <<< 12 ||| (v &&& 0xF8) <<< 2, w: 0}

  # $2006 PPUADDR: first write is the high 6 bits, second the low 8 (then v := t).
  defp reg_write(%{w: 0} = ppu, 0x2006, v),
    do: %{ppu | t: (ppu.t &&& 0x00FF) ||| (v &&& 0x3F) <<< 8, w: 1}

  defp reg_write(%{w: 1} = ppu, 0x2006, v) do
    t = (ppu.t &&& 0x7F00) ||| v
    %{ppu | t: t, v: t, w: 0}
  end

  defp reg_write(ppu, 0x2007, v) do
    write(ppu, ppu.v &&& 0x3FFF, v)
    |> Map.update!(:v, &(&1 + vram_step(ppu) &&& 0x7FFF))
  end

  defp reg_write(ppu, _addr, _v), do: ppu

  defp vram_step(ppu), do: if((ppu.ctrl &&& 0x04) != 0, do: 32, else: 1)

  # --- internal PPU address space ($0000-$3FFF) ---

  defp read(ppu, addr) when addr in 0x0000..0x1FFF, do: chr_at(ppu, addr, ppu.chr_banks)

  defp read(ppu, addr) when addr in 0x2000..0x3EFF, do: nt_read(ppu, addr)

  defp read(ppu, addr) when addr in 0x3F00..0x3FFF,
    do: Map.get(ppu.palette, palette_addr(addr), 0)

  # Standard mirroring maps into CIRAM. MMC5's $5105 instead sources each of the
  # four nametables independently: CIRAM page 0/1, ExRAM, or fill mode.
  defp nt_read(%{nt_source: nil} = ppu, addr), do: :binary.at(ppu.vram, nametable(ppu, addr))

  defp nt_read(ppu, addr) do
    off = addr &&& 0x03FF

    case elem(ppu.nt_source, addr >>> 10 &&& 3) do
      0 -> :binary.at(ppu.vram, off)
      1 -> :binary.at(ppu.vram, 0x400 + off)
      2 -> Map.get(ppu.exram, off, 0)
      3 -> if off < 0x3C0, do: ppu.fill_tile, else: ppu.fill_attr * 0x55
    end
  end

  # CHR byte via a given eight-1KB-window bank set (mapper-controlled).
  defp chr_at(ppu, addr, banks) do
    off = elem(banks, addr >>> 10) + (addr &&& 0x03FF)
    if byte_size(ppu.chr) > 0, do: :binary.at(ppu.chr, off), else: Map.get(ppu.chr_ram, off, 0)
  end

  # Background fetches use the dedicated bg set only in 8x16 sprite mode (MMC5).
  defp bg_banks(ppu), do: if((ppu.ctrl &&& 0x20) != 0, do: ppu.bg_chr_banks, else: ppu.chr_banks)

  defp write(ppu, addr, v) when addr in 0x0000..0x1FFF do
    # CHR-ROM is read-only; only CHR-RAM boards accept writes.
    off = elem(ppu.chr_banks, addr >>> 10) + (addr &&& 0x03FF)
    if byte_size(ppu.chr) > 0, do: ppu, else: %{ppu | chr_ram: Map.put(ppu.chr_ram, off, v)}
  end

  defp write(ppu, addr, v) when addr in 0x2000..0x3EFF, do: nt_write(ppu, addr, v)

  defp write(ppu, addr, v) when addr in 0x3F00..0x3FFF,
    do: %{ppu | palette: Map.put(ppu.palette, palette_addr(addr), v)}

  # Writes must land in the same place reads source from (see `nt_read/2`):
  # standard mirroring into CIRAM, or MMC5's $5105 per-nametable target. A slot
  # mapped to fill mode is read-only, so the write is dropped.
  defp nt_write(%{nt_source: nil} = ppu, addr, v),
    do: %{ppu | vram: put_byte(ppu.vram, nametable(ppu, addr), v)}

  defp nt_write(ppu, addr, v) do
    off = addr &&& 0x03FF

    case elem(ppu.nt_source, addr >>> 10 &&& 3) do
      0 -> %{ppu | vram: put_byte(ppu.vram, off, v)}
      1 -> %{ppu | vram: put_byte(ppu.vram, 0x400 + off, v)}
      2 -> %{ppu | exram: Map.put(ppu.exram, off, v)}
      3 -> ppu
    end
  end

  # Replace one byte of a fixed-size binary (VRAM/OAM are read-heavy, write-light).
  defp put_byte(bin, idx, v) do
    <<pre::binary-size(^idx), _old, post::binary>> = bin
    <<pre::binary, v, post::binary>>
  end

  # Map a nametable address into the 2KB physical VRAM per the mirroring wiring.
  defp nametable(ppu, addr) do
    a = addr &&& 0x0FFF
    bank = nt_bank(ppu.mirroring, a)
    bank * 0x400 + (a &&& 0x3FF)
  end

  defp nt_bank(:horizontal, a), do: a >>> 11 &&& 1
  defp nt_bank(:vertical, a), do: a >>> 10 &&& 1
  defp nt_bank(:single, _a), do: 0
  defp nt_bank(:single0, _a), do: 0
  defp nt_bank(:single1, _a), do: 1
  defp nt_bank(:four, a), do: a >>> 10 &&& 3

  # Palette RAM is 32 bytes; $3F10/$14/$18/$1C mirror the backdrop entries.
  defp palette_addr(addr) do
    a = addr &&& 0x1F
    if (a &&& 0x13) == 0x10, do: a - 0x10, else: a
  end

  # --- OAM ($2004) — sprite attribute byte (index rem 4 == 2) reads masked $E3 ---

  defp oam_read(ppu, addr) do
    byte = :binary.at(ppu.oam, addr)
    if rem(addr, 4) == 2, do: byte &&& 0xE3, else: byte
  end

  defp oam_write(ppu, addr, v), do: %{ppu | oam: put_byte(ppu.oam, addr, v)}

  @doc """
  Load all 256 OAM bytes at once (OAMDMA). The copy starts at the current OAMADDR
  and wraps, but OAMADDR is unchanged afterwards (256 increments wrap to itself).
  """
  def oam_dma(ppu, <<_::size(256 * 8)>> = bytes) when ppu.oam_addr == 0,
    do: %{ppu | oam: bytes}

  def oam_dma(ppu, <<_::size(256 * 8)>> = bytes) do
    k = ppu.oam_addr
    %{ppu | oam: binary_part(bytes, 256 - k, k) <> binary_part(bytes, 0, 256 - k)}
  end
end
