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
            bg_banks: 1,
            advance: 4}

  defstruct ctrl: 0,
            mask: 0,
            status: 0,
            oam_addr: 0,
            v: 0,
            t: 0,
            x: 0,
            w: 0,
            buffer: 0,
            vram: %{},
            palette: %{},
            oam: %{},
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
            fb: [],
            frame_ready: nil

  @doc "Build a PPU over the cartridge's CHR data and nametable mirroring."
  def new(chr, mirroring), do: %__MODULE__{chr: chr, mirroring: mirroring}

  # --- dot timing (spec §3): 341 dots/scanline, 262 scanlines/frame ---
  # Scanline 241 dot 1 raises vblank; the pre-render line 261 dot 1 clears
  # vblank + sprite-0 + overflow. The NMI line is the level (vblank AND
  # PPUCTRL bit 7); the CPU polls it per cycle and detects the edge.

  @doc "Advance the PPU by `dots`."
  def run(ppu, 0), do: ppu
  def run(ppu, dots), do: run(tick(ppu), dots - 1)

  @doc "Current NMI output line level: vblank flag set AND NMI enabled."
  def nmi_line?(ppu), do: (ppu.status &&& 0x80) != 0 and (ppu.ctrl &&& 0x80) != 0

  defp tick(ppu) do
    rendering = (ppu.mask &&& 0x18) != 0
    {scanline, dot, frame} = advance(ppu.scanline, ppu.dot, ppu.frame, rendering)
    ppu = %{ppu | scanline: scanline, dot: dot, frame: frame}

    # Run the fetch/scroll pipeline on visible + pre-render lines while rendering
    # is enabled; emit one pixel per visible dot regardless (backdrop when off).
    ppu =
      if rendering and (scanline <= 239 or scanline == 261) do
        ppu = pipeline(ppu, scanline, dot)

        # Evaluate sprites for the visible scanline at its start (secondary-OAM fill).
        ppu = if scanline <= 239 and dot == 0, do: eval_sprites(ppu), else: ppu

        # Flag a scanline-IRQ clock for MMC3 (approximation of the A12 rise).
        if dot == 260, do: %{ppu | irq_ticks: ppu.irq_ticks + 1}, else: ppu
      else
        ppu
      end

    ppu = if scanline <= 239 and dot in 1..256, do: emit_pixel(ppu), else: ppu

    cond do
      scanline == 240 and dot == 0 -> finish_frame(ppu)
      scanline == 241 and dot == 1 -> %{ppu | status: ppu.status ||| 0x80}
      scanline == 261 and dot == 1 -> %{ppu | status: ppu.status &&& bxor(0xFF, 0xE0)}
      true -> ppu
    end
  end

  # --- background render pipeline (spec §5.2 item 1) ---
  # Runs on visible (0-239) and pre-render (261) scanlines. Each dot in the fetch
  # window shifts the two 16-bit pattern registers and the two attribute
  # registers; every 8 dots a tile's nametable/attribute/pattern bytes are
  # fetched and reloaded. Fine-x selects the output bit; the pixel is the 4-bit
  # palette RAM address (backdrop 0 when the pattern bits are 0).

  defp pipeline(ppu, s, d) do
    ppu = if d in 1..256 or d in 321..336, do: fetch_shift(ppu, d), else: ppu
    ppu = if d == 256, do: inc_vert(ppu), else: ppu
    ppu = if d == 257, do: copy_hori(ppu), else: ppu
    if s == 261 and d in 280..304, do: copy_vert(ppu), else: ppu
  end

  defp fetch_shift(ppu, d) do
    ppu = shift(ppu)

    case rem(d - 1, 8) do
      0 -> ppu |> reload() |> fetch_nt()
      2 -> fetch_at(ppu)
      4 -> fetch_bg(ppu, :lo)
      6 -> fetch_bg(ppu, :hi)
      7 -> inc_hori(ppu)
      _ -> ppu
    end
  end

  # Emit one pixel: composite background and sprites with priority, detecting
  # sprite-0 hit (spec §5.2 item 4). Background/sprite enable and the left-8px
  # clip come from PPUMASK.
  defp emit_pixel(ppu) do
    x = ppu.dot - 1
    {bg_pat, bg_addr} = bg_pixel(ppu, x)
    {sp_pat, sp_addr, sp_front?, sp_zero?} = sprite_pixel(ppu, x)

    bg_op = bg_pat != 0
    sp_op = sp_pat != 0

    ppu =
      if sp_zero? and sp_op and bg_op and x != 255 and not clipped?(ppu, x) and
           bg_on?(ppu) and sprites_on?(ppu),
         do: %{ppu | status: ppu.status ||| 0x40},
         else: ppu

    addr =
      cond do
        sp_op and (not bg_op or sp_front?) -> sp_addr
        bg_op -> bg_addr
        true -> 0
      end

    %{ppu | fb: [addr | ppu.fb]}
  end

  defp bg_on?(ppu), do: (ppu.mask &&& 0x08) != 0
  defp sprites_on?(ppu), do: (ppu.mask &&& 0x10) != 0

  # Left-8px clip suppresses sprite-0 hit (and rendering) when either the
  # background (bit 1) or sprite (bit 2) clip is active.
  defp clipped?(ppu, x), do: x < 8 and ((ppu.mask &&& 0x02) == 0 or (ppu.mask &&& 0x04) == 0)

  defp bg_pixel(ppu, x) do
    cond do
      not bg_on?(ppu) ->
        {0, 0}

      x < 8 and (ppu.mask &&& 0x02) == 0 ->
        {0, 0}

      true ->
        bit = 15 - ppu.x
        pattern = sel(ppu.bg_hi, bit) <<< 1 ||| sel(ppu.bg_lo, bit)
        attr = sel(ppu.at_hi, bit) <<< 1 ||| sel(ppu.at_lo, bit)
        {pattern, if(pattern == 0, do: 0, else: attr <<< 2 ||| pattern)}
    end
  end

  # First (front-most in OAM order) opaque sprite pixel covering column x.
  defp sprite_pixel(ppu, x) do
    if sprites_on?(ppu) and not (x < 8 and (ppu.mask &&& 0x04) == 0),
      do: scan_sprites(ppu.line_sprites, x),
      else: {0, 0, false, false}
  end

  defp scan_sprites([], _x), do: {0, 0, false, false}

  defp scan_sprites([sp | rest], x) do
    col = x - sp.x

    if col >= 0 and col <= 7 do
      bit = 7 - col
      pat = sel(sp.hi, bit) <<< 1 ||| sel(sp.lo, bit)

      if pat != 0 do
        addr = 0x10 ||| (sp.attr &&& 0x03) <<< 2 ||| pat
        {pat, addr, (sp.attr &&& 0x20) == 0, sp.index == 0}
      else
        scan_sprites(rest, x)
      end
    else
      scan_sprites(rest, x)
    end
  end

  defp sel(reg, bit), do: reg >>> bit &&& 1

  # --- sprite evaluation (spec §5.2 item 4) ---
  # Scan the 64 OAM entries for those on this scanline, keeping the first 8 (OAM
  # order = priority). A 9th sets the overflow flag. Sprite Y is stored one line
  # early, so a sprite at OAM Y renders on scanlines Y+1..Y+height.

  defp eval_sprites(ppu) do
    height = if (ppu.ctrl &&& 0x20) != 0, do: 16, else: 8

    {sprites, count} =
      Enum.reduce(0..63, {[], 0}, fn i, {acc, count} ->
        row = ppu.scanline - Map.get(ppu.oam, i * 4, 0) - 1

        cond do
          row < 0 or row >= height -> {acc, count}
          count < 8 -> {[build_sprite(ppu, i, row, height) | acc], count + 1}
          true -> {acc, count + 1}
        end
      end)

    status = if count > 8, do: ppu.status ||| 0x20, else: ppu.status
    %{ppu | line_sprites: Enum.reverse(sprites), status: status}
  end

  defp build_sprite(ppu, i, row, height) do
    base = i * 4
    tile = Map.get(ppu.oam, base + 1, 0)
    attr = Map.get(ppu.oam, base + 2, 0)
    x = Map.get(ppu.oam, base + 3, 0)
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

  defp shift(ppu) do
    %{
      ppu
      | bg_lo: ppu.bg_lo <<< 1 &&& 0xFFFF,
        bg_hi: ppu.bg_hi <<< 1 &&& 0xFFFF,
        at_lo: ppu.at_lo <<< 1 &&& 0xFFFF,
        at_hi: ppu.at_hi <<< 1 &&& 0xFFFF
    }
  end

  defp reload(ppu) do
    %{
      ppu
      | bg_lo: (ppu.bg_lo &&& 0xFF00) ||| ppu.bg_lo_latch,
        bg_hi: (ppu.bg_hi &&& 0xFF00) ||| ppu.bg_hi_latch,
        at_lo: (ppu.at_lo &&& 0xFF00) ||| if((ppu.at_latch &&& 1) != 0, do: 0xFF, else: 0),
        at_hi: (ppu.at_hi &&& 0xFF00) ||| if((ppu.at_latch &&& 2) != 0, do: 0xFF, else: 0)
    }
  end

  defp fetch_nt(ppu) do
    cond do
      # Vertical split: tiles come from ExRAM at the split's own vertical position.
      split_active?(ppu) ->
        {cy, _} = split_yc(ppu)
        %{ppu | nt_latch: Map.get(ppu.exram, cy * 32 + (ppu.v &&& 0x1F), 0), ext_latch: 0}

      # Extended-attribute mode ($5104=1): this tile's ExRAM byte gives its CHR
      # bank (bits 0-5) and palette (bits 6-7).
      ppu.exram_mode == 1 ->
        nt = read(ppu, 0x2000 ||| (ppu.v &&& 0x0FFF))
        %{ppu | nt_latch: nt, ext_latch: Map.get(ppu.exram, ppu.v &&& 0x03FF, 0)}

      true ->
        %{ppu | nt_latch: read(ppu, 0x2000 ||| (ppu.v &&& 0x0FFF)), ext_latch: 0}
    end
  end

  # The vertical split replaces a contiguous column range with ExRAM-sourced tiles.
  defp split_active?(ppu),
    do: ppu.split_en and split_region?(ppu.split_side, ppu.split_tile, ppu.v &&& 0x1F)

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
        %{ppu | at_latch: read(ppu, addr) >>> quadrant &&& 0x03}
    end
  end

  defp fetch_bg(ppu, half) do
    fine_y = ppu.v >>> 12 &&& 0x07
    {addr, byte} = bg_pattern(ppu, fine_y, if(half == :hi, do: 8, else: 0))

    ppu =
      case half do
        :lo -> %{ppu | bg_lo_latch: byte}
        :hi -> %{ppu | bg_hi_latch: byte}
      end

    apply_chr_latch(ppu, addr)
  end

  # In extended-attribute mode the tile's CHR comes from a flat per-tile 4KB bank
  # (ExRAM); otherwise from the PPU pattern address through the bg bank set.
  defp bg_pattern(ppu, fine_y, plane) do
    cond do
      split_active?(ppu) ->
        {_, fy} = split_yc(ppu)
        off = ppu.split_chr * 0x1000 + (ppu.nt_latch <<< 4) + fy + plane
        {off, chr_flat(ppu, off)}

      ppu.exram_mode == 1 ->
        bank = (ppu.ext_latch &&& 0x3F) ||| ppu.ext_chr_hi <<< 6
        off = bank * 0x1000 + (ppu.nt_latch <<< 4) + fine_y + plane
        {off, chr_flat(ppu, off)}

      true ->
        addr = (ppu.ctrl &&& 0x10) <<< 8 ||| ppu.nt_latch <<< 4 ||| fine_y
        {addr + plane, chr_at(ppu, addr + plane, bg_banks(ppu))}
    end
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

  defp copy_hori(ppu), do: %{ppu | v: (ppu.v &&& bxor(0x7FFF, 0x041F)) ||| (ppu.t &&& 0x041F)}
  defp copy_vert(ppu), do: %{ppu | v: (ppu.v &&& bxor(0x7FFF, 0x7BE0)) ||| (ppu.t &&& 0x7BE0)}

  defp finish_frame(ppu) do
    pixels = ppu.fb |> Enum.reverse() |> :binary.list_to_bin()
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

  # Odd-frame dot skip (spec §5.2 item 5): with rendering enabled, the pre-render
  # line jumps from (261,339) straight to (0,0), one dot short.
  defp advance(261, 339, frame, true) when (frame &&& 1) == 1, do: {0, 0, frame + 1}
  defp advance(261, 340, frame, _), do: {0, 0, frame + 1}
  defp advance(scanline, 340, frame, _), do: {scanline + 1, 0, frame}
  defp advance(scanline, dot, frame, _), do: {scanline, dot + 1, frame}

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
  defp nt_read(%{nt_source: nil} = ppu, addr), do: Map.get(ppu.vram, nametable(ppu, addr), 0)

  defp nt_read(ppu, addr) do
    off = addr &&& 0x03FF

    case elem(ppu.nt_source, addr >>> 10 &&& 3) do
      0 -> Map.get(ppu.vram, off, 0)
      1 -> Map.get(ppu.vram, 0x400 + off, 0)
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

  defp write(ppu, addr, v) when addr in 0x2000..0x3EFF,
    do: %{ppu | vram: Map.put(ppu.vram, nametable(ppu, addr), v)}

  defp write(ppu, addr, v) when addr in 0x3F00..0x3FFF,
    do: %{ppu | palette: Map.put(ppu.palette, palette_addr(addr), v)}

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
    byte = Map.get(ppu.oam, addr, 0)
    if rem(addr, 4) == 2, do: byte &&& 0xE3, else: byte
  end

  defp oam_write(ppu, addr, v), do: %{ppu | oam: Map.put(ppu.oam, addr, v)}
end
