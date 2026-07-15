defmodule Beamicom.NES.Mapper do
  @moduledoc """
  Cartridge mappers, spanning both buses (spec §5.3, §9): register writes set PRG
  bank offsets on the `%Bus{}` (four 8KB windows) and CHR bank offsets + nametable
  mirroring on the PPU the bus holds (eight 1KB windows). Reads use the offsets
  directly, so only `reset/1`, `write/3`, and the MMC3 `clock_irq/2` live here.

  Implemented:
    * 0  NROM
    * 1  MMC1 — serial shift register (PRG/CHR banking + mirroring)
    * 2  UxROM — 16KB PRG switch
    * 3  CNROM — 8KB CHR switch
    * 4  MMC3 — 8 bank registers + scanline IRQ
    * 7  AxROM — 32KB PRG + single-screen page select
    * 9  MMC2 / 10 MMC4 — CHR banks latched by $xFD8/$xFE8 pattern fetches
    * 11 Color Dreams / 66 GxROM — combined PRG+CHR bank byte
    * 69 Sunsoft FME-7 — command/param ports + a CPU-cycle IRQ

    * 5  MMC5 — mode-aware PRG/CHR banking (separate sprite/bg CHR), $5105 per-
      nametable sources + fill mode, ExRAM (all four modes incl. extended
      attributes), the multiplier, scanline IRQ, the vertical split
      ($5200-$5202), and the two pulse + PCM sound channels:
      https://www.nesdev.org/wiki/MMC5

  ## Adding a mapper

  Add a `reset/1` clause (power-on bank layout) and a `write/3` clause (register
  decode), reusing `set_prg/2` (four 8KB windows), `set_chr/2` (eight 1KB
  windows), `set_prg32/2`/`set_chr8/2`, `mirror/2`, and the `b/2`/`c/2` offset
  helpers. CHR-latch mappers use `Beamicom.NES.PPU`'s `chr_latch` + `relatch/1`; scanline-
  IRQ mappers use `clock_irq/2`, CPU-cycle-IRQ mappers `clock_cpu_irq/2` (both
  backed by `%Bus{}` IRQ fields). Full mapper list:
  https://www.nesdev.org/wiki/Mapper

  ## Sources
    * NESdev Wiki — NROM / MMC1 / UxROM / CNROM / MMC3 / AxROM / MMC2 / MMC4 /
      Color Dreams / GxROM / Sunsoft FME-7 / MMC5.
  """

  import Bitwise

  @compile {:inline, b: 2, c: 2, banks8: 1, banks16: 1, chr_reg_index: 1, set_prg_window: 3}

  # --- power-on bank layout ---

  def reset(%{mapper: 2} = bus),
    do: set_prg(bus, [b(bus, 0), b(bus, 1), b(bus, banks8(bus) - 2), b(bus, banks8(bus) - 1)])

  def reset(%{mapper: 1} = bus), do: apply_mmc1(bus)
  def reset(%{mapper: 4} = bus), do: apply_mmc3(bus)
  def reset(%{mapper: 7} = bus), do: axrom(bus, 0)
  # FME-7: $E000 is fixed to the last 8KB bank; $8000/$A000/$C000 switch.
  def reset(%{mapper: 69} = bus),
    do: set_prg(bus, [b(bus, 0), b(bus, 1), b(bus, 2), b(bus, banks8(bus) - 1)])

  # MMC2/4: two CHR latches default to FE; PRG bank 0 switchable, rest fixed high.
  def reset(%{mapper: m} = bus) when m in [9, 10] do
    latch = %{l0: :fe, l1: :fe, fd0: 0, fe0: 0, fd1: 0, fe1: 0}
    bus = %{bus | ppu: Beamicom.NES.PPU.relatch(%{bus.ppu | chr_latch: latch})}
    mmc24_prg(bus, m, 0)
  end

  # MMC5 (basic): 8KB PRG windows with $E000 fixed high, CHR 1KB banks.
  def reset(%{mapper: 5} = bus),
    do: set_prg(bus, [b(bus, 0), b(bus, 1), b(bus, 2), b(bus, banks8(bus) - 1)])

  # NROM: map $8000-$FFFF linearly over PRG (a 16KB image mirrors into both halves).
  def reset(bus), do: set_prg(bus, for(w <- 0..3, do: b(bus, w)))

  # --- register writes ---

  def write(%{mapper: 2} = bus, _addr, val) do
    bank = (val &&& 0x0F) * 2
    set_prg(bus, [b(bus, bank), b(bus, bank + 1), elem(bus.prg_banks, 2), elem(bus.prg_banks, 3)])
  end

  def write(%{mapper: 1} = bus, addr, val), do: mmc1(bus, addr, val)
  def write(%{mapper: 4} = bus, addr, val), do: mmc3(bus, addr, val)
  def write(%{mapper: 7} = bus, _addr, val), do: axrom(bus, val)

  # CNROM: fixed PRG, switch the 8KB CHR bank.
  def write(%{mapper: 3} = bus, _addr, val), do: set_chr8(bus, val &&& 0x03)

  # Color Dreams: PRG 32KB in bits 0-1, CHR 8KB in bits 4-7.
  def write(%{mapper: 11} = bus, _addr, val),
    do: bus |> set_prg32(val &&& 0x03) |> set_chr8(val >>> 4 &&& 0x0F)

  # GxROM: PRG 32KB in bits 4-5, CHR 8KB in bits 0-1.
  def write(%{mapper: 66} = bus, _addr, val),
    do: bus |> set_prg32(val >>> 4 &&& 0x03) |> set_chr8(val &&& 0x03)

  def write(%{mapper: 69} = bus, addr, val), do: fme7(bus, addr, val)
  def write(%{mapper: m} = bus, addr, val) when m in [9, 10], do: mmc24(bus, m, addr, val)
  def write(%{mapper: 5} = bus, addr, val), do: mmc5(bus, addr, val)

  def write(bus, _addr, _val), do: bus

  # MMC5 (basic subset): 8KB PRG banks ($5114-$5117), 1KB CHR banks
  # ($5120-$5127), and the common mirroring patterns ($5105). NOT implemented:
  # ExRAM, vertical split, the multiplier, extended attributes, the extra sound
  # channels, and the scanline IRQ — see the moduledoc pointer.
  defp mmc5(bus, addr, val) do
    cond do
      addr == 0x5100 ->
        %{bus | prg_mode: val &&& 0x03}

      addr == 0x5101 ->
        mmc5_chr(%{bus | chr_mode: val &&& 0x03})

      addr == 0x5104 ->
        put_ppu(bus, :exram_mode, val &&& 0x03)

      addr == 0x5105 ->
        # Per-nametable source: 2 bits each for $2000/$2400/$2800/$2C00.
        src = {val &&& 3, val >>> 2 &&& 3, val >>> 4 &&& 3, val >>> 6 &&& 3}
        put_ppu(bus, :nt_source, src)

      addr == 0x5106 ->
        put_ppu(bus, :fill_tile, val)

      addr == 0x5107 ->
        put_ppu(bus, :fill_attr, val &&& 0x03)

      addr in 0x5C00..0x5FFF ->
        put_ppu(bus, :exram, Map.put(bus.ppu.exram, addr - 0x5C00, val))

      addr in 0x5114..0x5117 ->
        mmc5_prg(bus, addr - 0x5114, val &&& 0x7F)

      addr in 0x5120..0x512B ->
        mmc5_chr(%{bus | chr_regs: put_elem(bus.chr_regs, chr_reg_index(addr), val)})

      addr == 0x5130 ->
        mmc5_chr(put_ppu(%{bus | chr_hi: val &&& 0x03}, :ext_chr_hi, val &&& 0x03))

      # Scanline IRQ: $5203 = compare target, $5204 bit7 = enable.
      addr == 0x5203 ->
        %{bus | irq_latch: val}

      addr == 0x5204 ->
        %{bus | irq_enabled: (val &&& 0x80) != 0}

      # 8x8 unsigned multiplier.
      addr == 0x5205 ->
        %{bus | mul_a: val}

      addr == 0x5206 ->
        %{bus | mul_b: val}

      # Vertical split: $5200 enable/side/threshold, $5201 scroll, $5202 CHR bank.
      addr == 0x5200 ->
        bus
        |> put_ppu(:split_en, (val &&& 0x80) != 0)
        |> put_ppu(:split_side, val >>> 6 &&& 1)
        |> put_ppu(:split_tile, val &&& 0x1F)

      addr == 0x5201 ->
        put_ppu(bus, :split_scroll, val)

      addr == 0x5202 ->
        put_ppu(bus, :split_chr, val)

      true ->
        bus
    end
  end

  @doc "MMC5 readable registers: $5204 status (clears IRQ) and the $5205/$5206 product."
  def read(%{mapper: 5} = bus, 0x5204) do
    in_frame = bus.ppu != nil and bus.ppu.scanline < 240
    value = if(bus.irq_pending, do: 0x80, else: 0) ||| if(in_frame, do: 0x40, else: 0)
    {value, %{bus | irq_pending: false}}
  end

  def read(%{mapper: 5} = bus, 0x5205), do: {bus.mul_a * bus.mul_b &&& 0xFF, bus}
  def read(%{mapper: 5} = bus, 0x5206), do: {(bus.mul_a * bus.mul_b) >>> 8 &&& 0xFF, bus}
  # ExRAM is CPU-readable in the work-RAM modes (2/3).
  def read(%{mapper: 5, ppu: %{exram_mode: m, exram: ex}} = bus, addr)
      when addr in 0x5C00..0x5FFF and m in [2, 3],
      do: {Map.get(ex, addr - 0x5C00, 0), bus}

  def read(bus, _addr), do: {0, bus}

  defp put_ppu(bus, key, value), do: %{bus | ppu: Map.put(bus.ppu, key, value)}

  # MMC5 scanline counter (NESdev "MMC5#Scanline Detection and Scanline IRQ"):
  # the counter is the in-frame rendered-scanline number, reset to 0 every frame,
  # NOT a free-running tick count — so the IRQ fires at the same scanline each
  # frame (while the CPU sits in its idle loop), matching hardware. We take the
  # frame-synced scanline the PPU captured at the tick (`ppu.irq_scanline`).
  #
  # The pending flag latches whenever the counter matches $5203, regardless of the
  # enable bit (NESdev). $5203 = 0 is a special case that never matches. The enable
  # bit only gates whether /IRQ is actually asserted — see `Bus.irq_pending?/1`.
  defp mmc5_scanline(bus) do
    sl = bus.ppu.irq_scanline

    %{
      bus
      | irq_counter: sl,
        irq_pending: bus.irq_pending or (sl == bus.irq_latch and bus.irq_latch != 0)
    }
  end

  # PRG window mapping depends on $5100 mode (NESdev): mode 3 = four 8KB, mode 2 =
  # 16KB@$8000 + two 8KB, mode 1 = two 16KB, mode 0 = one 32KB. $5117 ($E000) is
  # always ROM. `bank` is an 8KB index (bit 7 ROM/RAM is treated as ROM).
  defp mmc5_prg(bus, reg, bank) do
    case {bus.prg_mode, reg} do
      {3, w} -> set_prg_window(bus, w, b(bus, bank))
      {2, 1} -> set_prg16(bus, 0, bank)
      {2, 2} -> set_prg_window(bus, 2, b(bus, bank))
      {2, 3} -> set_prg_window(bus, 3, b(bus, bank))
      {1, 1} -> set_prg16(bus, 0, bank)
      {1, 3} -> set_prg16(bus, 2, bank)
      {0, 3} -> Enum.reduce(0..3, bus, &set_prg_window(&2, &1, b(&2, (bank &&& 0x7C) + &1)))
      _ -> bus
    end
  end

  # 16KB PRG at window w/w+1 (bit 0 of the bank index ignored).
  defp set_prg16(bus, w, bank) do
    base = bank &&& 0x7E
    bus |> set_prg_window(w, b(bus, base)) |> set_prg_window(w + 1, b(bus, base + 1))
  end

  # $5120-$5127 sprite CHR → chr_regs 0-7; $5128-$512B background → chr_regs 8-11.
  defp chr_reg_index(addr) when addr in 0x5120..0x5127, do: addr - 0x5120
  defp chr_reg_index(addr), do: 8 + (addr - 0x5128)

  # Expand the CHR registers into two 8x1KB window sets per the CHR mode ($5101):
  # sprites from $5120-$5127, background from $5128-$512B (used in 8x16 mode).
  defp mmc5_chr(bus) do
    sprite = for w <- 0..7, do: chr_off(bus, elem(bus.chr_regs, sprite_reg(bus.chr_mode, w)), w)
    bg = for w <- 0..7, do: chr_off(bus, elem(bus.chr_regs, 8 + bg_reg(bus.chr_mode, w)), w)
    %{bus | ppu: %{bus.ppu | chr_banks: List.to_tuple(sprite), bg_chr_banks: List.to_tuple(bg)}}
  end

  # Which register controls 1KB window w, per mode (bank window sizes 8/4/2/1 KB).
  defp sprite_reg(3, w), do: w
  defp sprite_reg(2, w), do: w ||| 1
  defp sprite_reg(1, w), do: if(w < 4, do: 3, else: 7)
  defp sprite_reg(0, _w), do: 7

  defp bg_reg(3, w), do: w &&& 3
  defp bg_reg(2, w), do: if((w &&& 2) == 0, do: 1, else: 3)
  defp bg_reg(_m, _w), do: 3

  defp chr_off(bus, reg, w) do
    win = elem({8, 4, 2, 1}, bus.chr_mode)
    local = elem({w, w &&& 0x03, w &&& 0x01, 0}, bus.chr_mode)
    bank = reg ||| bus.chr_hi <<< 8
    size = max(byte_size(bus.ppu.chr), 0x2000)
    rem((bank * win + local) * 0x400 + size, size)
  end

  # MMC2 (9) / MMC4 (10): $A000 PRG bank; $B000-$E000 the four latched CHR banks
  # (table0-FD, table0-FE, table1-FD, table1-FE); $F000 mirroring.
  defp mmc24(bus, m, addr, val) do
    case addr >>> 12 do
      0xA -> mmc24_prg(bus, m, val)
      0xB -> mmc24_chr(bus, :fd0, val)
      0xC -> mmc24_chr(bus, :fe0, val)
      0xD -> mmc24_chr(bus, :fd1, val)
      0xE -> mmc24_chr(bus, :fe1, val)
      0xF -> mirror(bus, if((val &&& 1) == 0, do: :vertical, else: :horizontal))
      _ -> bus
    end
  end

  # MMC2 switches an 8KB bank at $8000 (last three fixed); MMC4 a 16KB bank.
  defp mmc24_prg(bus, 9, val),
    do: set_prg(bus, [b(bus, val &&& 0x0F) | Enum.map(1..3, &b(bus, banks8(bus) - 4 + &1))])

  defp mmc24_prg(bus, 10, val) do
    lo = (val &&& 0x0F) * 2
    set_prg(bus, [b(bus, lo), b(bus, lo + 1), b(bus, banks8(bus) - 2), b(bus, banks8(bus) - 1)])
  end

  defp mmc24_chr(bus, key, val) do
    latch = Map.put(bus.ppu.chr_latch, key, chr4k(bus, val &&& 0x1F))
    %{bus | ppu: Beamicom.NES.PPU.relatch(%{bus.ppu | chr_latch: latch})}
  end

  # AxROM: bits 0-2 select a 32KB PRG bank; bit 4 selects the single-screen page.
  defp axrom(bus, val) do
    bank = (val &&& 0x07) * 4
    page = if (val &&& 0x10) != 0, do: :single1, else: :single0

    bus
    |> set_prg([b(bus, bank), b(bus, bank + 1), b(bus, bank + 2), b(bus, bank + 3)])
    |> mirror(page)
  end

  # --- MMC1: 5-bit serial shift register ---

  def clock_irq(%{mapper: 4} = bus, n) when n > 0,
    do: Enum.reduce(1..n, bus, fn _, b -> tick_mmc3_irq(b) end)

  def clock_irq(%{mapper: 5} = bus, n) when n > 0, do: mmc5_scanline(bus)

  def clock_irq(bus, _n), do: bus

  defp mmc1(bus, _addr, val) when (val &&& 0x80) != 0,
    do: apply_mmc1(%{bus | shift: 0, shift_count: 0, ctrl: bus.ctrl ||| 0x0C})

  defp mmc1(bus, addr, val) do
    shift = bus.shift >>> 1 ||| (val &&& 1) <<< 4

    if bus.shift_count == 4 do
      bus = %{bus | shift: 0, shift_count: 0}

      case addr >>> 13 &&& 0x03 do
        0 -> apply_mmc1(%{bus | ctrl: shift})
        1 -> apply_mmc1(%{bus | chr0: shift})
        2 -> apply_mmc1(%{bus | chr1: shift})
        3 -> apply_mmc1(%{bus | prg_reg: shift})
      end
    else
      %{bus | shift: shift, shift_count: bus.shift_count + 1}
    end
  end

  defp apply_mmc1(bus) do
    {lo16, hi16} =
      case bus.ctrl >>> 2 &&& 0x03 do
        m when m in [0, 1] ->
          p = bus.prg_reg &&& 0x0E
          {p, p + 1}

        2 ->
          {0, bus.prg_reg &&& 0x0F}

        3 ->
          {bus.prg_reg &&& 0x0F, banks16(bus) - 1}
      end

    {clo, chi} =
      if (bus.ctrl &&& 0x10) == 0 do
        c = bus.chr0 &&& 0x1E
        {c, c + 1}
      else
        {bus.chr0, bus.chr1}
      end

    bus
    |> set_prg([b(bus, lo16 * 2), b(bus, lo16 * 2 + 1), b(bus, hi16 * 2), b(bus, hi16 * 2 + 1)])
    |> set_chr(chr4(bus, clo) ++ chr4(bus, chi))
    |> mirror(mmc1_mirror(bus.ctrl &&& 0x03))
  end

  defp mmc1_mirror(0), do: :single0
  defp mmc1_mirror(1), do: :single1
  defp mmc1_mirror(2), do: :vertical
  defp mmc1_mirror(3), do: :horizontal

  # --- MMC3: 8 bank registers + scanline IRQ ---

  defp mmc3(bus, addr, val) do
    case {addr &&& 0xE001, val} do
      {0x8000, v} -> apply_mmc3(%{bus | bank_select: v})
      {0x8001, v} -> apply_mmc3(%{bus | regs: put_elem(bus.regs, bus.bank_select &&& 0x07, v)})
      {0xA000, v} -> mirror(bus, if((v &&& 1) == 0, do: :vertical, else: :horizontal))
      {0xC000, v} -> %{bus | irq_latch: v}
      {0xC001, _} -> %{bus | irq_reload: true}
      {0xE000, _} -> %{bus | irq_enabled: false, irq_pending: false}
      {0xE001, _} -> %{bus | irq_enabled: true}
      _ -> bus
    end
  end

  defp apply_mmc3(bus) do
    r = bus.regs
    last = banks8(bus) - 1

    prg =
      if (bus.bank_select &&& 0x40) == 0 do
        [elem(r, 6), elem(r, 7), last - 1, last]
      else
        [last - 1, elem(r, 7), elem(r, 6), last]
      end

    lo = [
      elem(r, 0) &&& 0xFE,
      (elem(r, 0) &&& 0xFE) + 1,
      elem(r, 1) &&& 0xFE,
      (elem(r, 1) &&& 0xFE) + 1
    ]

    hi = [elem(r, 2), elem(r, 3), elem(r, 4), elem(r, 5)]
    chr = if (bus.bank_select &&& 0x80) == 0, do: lo ++ hi, else: hi ++ lo

    bus
    |> set_prg(Enum.map(prg, &b(bus, &1)))
    |> set_chr(Enum.map(chr, &c(bus, &1)))
  end

  defp tick_mmc3_irq(bus) do
    counter =
      if bus.irq_counter == 0 or bus.irq_reload, do: bus.irq_latch, else: bus.irq_counter - 1

    pending = bus.irq_pending or (counter == 0 and bus.irq_enabled)
    %{bus | irq_counter: counter, irq_reload: false, irq_pending: pending}
  end

  # --- FME-7 (Sunsoft): command/parameter ports + a CPU-cycle IRQ ---
  # $8000 latches which internal register; $A000 writes its parameter.

  defp fme7(bus, addr, val) when addr in 0x8000..0x9FFF, do: %{bus | fme_cmd: val &&& 0x0F}

  defp fme7(bus, addr, val) when addr in 0xA000..0xBFFF, do: fme7_param(bus, bus.fme_cmd, val)
  defp fme7(bus, _addr, _val), do: bus

  # Regs 0-7: 1KB CHR banks. 9/A/B: 8KB PRG at $8000/$A000/$C000. C: mirroring.
  # D: IRQ control (bit0 count enable, bit7 IRQ enable; also acks). E/F: counter.
  defp fme7_param(bus, cmd, val) when cmd in 0..7, do: set_chr_window(bus, cmd, c(bus, val))
  defp fme7_param(bus, 9, val), do: set_prg_window(bus, 0, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 10, val), do: set_prg_window(bus, 1, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 11, val), do: set_prg_window(bus, 2, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 12, val), do: mirror(bus, fme7_mirror(val &&& 0x03))

  defp fme7_param(bus, 13, val),
    do: %{
      bus
      | fme_count_on: (val &&& 1) != 0,
        irq_enabled: (val &&& 0x80) != 0,
        irq_pending: false
    }

  defp fme7_param(bus, 14, val), do: %{bus | irq_counter: (bus.irq_counter &&& 0xFF00) ||| val}

  defp fme7_param(bus, 15, val),
    do: %{bus | irq_counter: (bus.irq_counter &&& 0x00FF) ||| val <<< 8}

  defp fme7_param(bus, _cmd, _val), do: bus

  defp fme7_mirror(0), do: :vertical
  defp fme7_mirror(1), do: :horizontal
  defp fme7_mirror(2), do: :single0
  defp fme7_mirror(3), do: :single1

  # FME-7's 16-bit down-counter is clocked every CPU cycle; underflow raises IRQ.
  def clock_cpu_irq(%{mapper: 69} = bus, n) when n > 0,
    do: Enum.reduce(1..n, bus, fn _, b -> fme7_tick(b) end)

  def clock_cpu_irq(bus, _n), do: bus

  defp fme7_tick(%{fme_count_on: false} = bus), do: bus

  defp fme7_tick(%{irq_counter: 0} = bus),
    do: %{bus | irq_counter: 0xFFFF, irq_pending: bus.irq_pending or bus.irq_enabled}

  defp fme7_tick(bus), do: %{bus | irq_counter: bus.irq_counter - 1}

  # --- helpers ---

  defp banks8(bus), do: max(div(byte_size(bus.prg), 0x2000), 1)
  defp banks16(bus), do: max(div(byte_size(bus.prg), 0x4000), 1)

  # 8KB PRG bank number -> byte offset (wrapped to PRG size).
  defp b(bus, bank), do: rem(bank * 0x2000 + byte_size(bus.prg), byte_size(bus.prg))

  # 1KB CHR bank number -> byte offset (wrapped; CHR-RAM is 8KB).
  defp c(bus, bank) do
    size = max(byte_size(bus.ppu.chr), 0x2000)
    rem(bank * 0x400 + size, size)
  end

  # Four 1KB offsets making up a 4KB CHR bank (MMC1).
  defp chr4(bus, bank4), do: for(i <- 0..3, do: c(bus, bank4 * 4 + i))

  # 4KB CHR bank number -> byte offset (MMC2/4 latches).
  defp chr4k(bus, bank) do
    size = max(byte_size(bus.ppu.chr), 0x2000)
    rem(bank * 0x1000 + size, size)
  end

  defp set_prg(bus, [a, b, c, d]), do: %{bus | prg_banks: {a, b, c, d}}
  defp mirror(bus, m), do: %{bus | ppu: %{bus.ppu | mirroring: m}}

  # Background and sprite CHR share one bank set except on MMC5 (see mmc5_chr/1),
  # so the generic helpers write both.
  defp set_chr(bus, list) do
    banks = List.to_tuple(list)
    %{bus | ppu: %{bus.ppu | chr_banks: banks, bg_chr_banks: banks}}
  end

  defp set_chr_window(bus, w, off) do
    ppu = bus.ppu

    %{
      bus
      | ppu: %{
          ppu
          | chr_banks: put_elem(ppu.chr_banks, w, off),
            bg_chr_banks: put_elem(ppu.bg_chr_banks, w, off)
        }
    }
  end

  # 32KB PRG bank -> four 8KB windows.
  defp set_prg32(bus, bank), do: set_prg(bus, for(i <- 0..3, do: b(bus, bank * 4 + i)))

  # 8KB CHR bank -> eight 1KB windows.
  defp set_chr8(bus, bank), do: set_chr(bus, for(i <- 0..7, do: c(bus, bank * 8 + i)))

  defp set_prg_window(bus, w, off), do: %{bus | prg_banks: put_elem(bus.prg_banks, w, off)}
end
