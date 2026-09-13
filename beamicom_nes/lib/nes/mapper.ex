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
    * 34 BNROM — 32KB PRG switch
    * 118 TxSROM — MMC3 with CHR-controlled nametable selection
    * 119 TQROM — MMC3 with mixed CHR ROM/RAM banks
    * 206 DxROM / Namco 108 — simplified MMC3-style PRG/CHR banking

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
      Color Dreams / BNROM / GxROM / Sunsoft FME-7 / MMC5 / TxSROM / TQROM /
      DxROM.
  """

  import Bitwise

  @compile {:inline, b: 2, c: 2, banks8: 1, banks16: 1, chr_reg_index: 1, set_prg_window: 3}

  defp put_state(bus, key, value),
    do: %{bus | mapper_state: Map.put(bus.mapper_state, key, value)}

  defp merge_state(bus, values),
    do: %{bus | mapper_state: Map.merge(bus.mapper_state, values)}

  # --- power-on bank layout ---

  def reset(%{mapper: 2} = bus),
    do: set_prg(bus, [b(bus, 0), b(bus, 1), b(bus, banks8(bus) - 2), b(bus, banks8(bus) - 1)])

  def reset(%{mapper: 1} = bus), do: apply_mmc1(bus)
  def reset(%{mapper: mapper} = bus) when mapper in [4, 118, 119], do: apply_mmc3(bus)
  def reset(%{mapper: 7} = bus), do: axrom(bus, 0)
  def reset(%{mapper: 34} = bus), do: set_prg32(bus, 0)
  def reset(%{mapper: 206} = bus), do: apply_namco108(bus)
  # FME-7: $E000 is fixed to the last 8KB bank; $8000/$A000/$C000 switch.
  def reset(%{mapper: 69} = bus),
    do: set_prg(bus, [b(bus, 0), b(bus, 1), b(bus, 2), b(bus, banks8(bus) - 1)])

  # MMC2/4: two CHR latches default to FE; PRG bank 0 switchable, rest fixed high.
  def reset(%{mapper: m} = bus) when m in [9, 10] do
    latch = %{l0: :fe, l1: :fe, fd0: 0, fe0: 0, fd1: 0, fe1: 0}
    bus = %{bus | ppu: Beamicom.NES.PPU.relatch(%{bus.ppu | chr_latch: latch})}
    mmc24_prg(bus, m, 0)
  end

  # MMC5: mode-aware PRG windows with $E000 fixed to ROM, CHR 1KB banks.
  def reset(%{mapper: 5} = bus), do: apply_mmc5_prg(bus)

  # NROM: map $8000-$FFFF linearly over PRG (a 16KB image mirrors into both halves).
  def reset(bus), do: set_prg(bus, for(w <- 0..3, do: b(bus, w)))

  # --- register writes ---

  def write(%{mapper: 2} = bus, _addr, val) do
    bank = (val &&& 0x0F) * 2
    set_prg(bus, [b(bus, bank), b(bus, bank + 1), elem(bus.prg_banks, 2), elem(bus.prg_banks, 3)])
  end

  def write(%{mapper: 1} = bus, addr, val), do: mmc1(bus, addr, val)

  def write(%{mapper: mapper} = bus, addr, val) when mapper in [4, 118, 119],
    do: mmc3(bus, addr, val)

  def write(%{mapper: 7} = bus, _addr, val), do: axrom(bus, val)
  def write(%{mapper: 34} = bus, _addr, val), do: set_prg32(bus, val)
  def write(%{mapper: 206} = bus, addr, val), do: namco108(bus, addr, val)

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

  # MMC5 register decode: mode-aware PRG/CHR banking, ExRAM/nametable routing,
  # vertical split, multiplier, scanline IRQ, and expansion audio control.
  defp mmc5(bus, addr, val) do
    cond do
      addr == 0x5100 ->
        bus |> put_state(:prg_mode, val &&& 0x03) |> apply_mmc5_prg()

      addr == 0x5101 ->
        bus |> put_state(:chr_mode, val &&& 0x03) |> mmc5_chr()

      addr == 0x5102 ->
        put_state(bus, :m5_protect1, val &&& 0x03)

      addr == 0x5103 ->
        put_state(bus, :m5_protect2, val &&& 0x03)

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

      addr in 0x5113..0x5117 ->
        reg = addr - 0x5113
        regs = put_elem(bus.mapper_state.m5_prg_regs, reg, val)
        bus |> put_state(:m5_prg_regs, regs) |> apply_mmc5_prg()

      addr in 0x5120..0x512B ->
        regs = put_elem(bus.mapper_state.chr_regs, chr_reg_index(addr), val)
        bus |> put_state(:chr_regs, regs) |> mmc5_chr()

      addr == 0x5130 ->
        bus
        |> put_state(:chr_hi, val &&& 0x03)
        |> put_ppu(:ext_chr_hi, val &&& 0x03)
        |> mmc5_chr()

      # Scanline IRQ: $5203 = compare target, $5204 bit7 = enable.
      addr == 0x5203 ->
        put_state(bus, :irq_latch, val)

      addr == 0x5204 ->
        %{bus | irq_enabled: (val &&& 0x80) != 0}

      # 8x8 unsigned multiplier.
      addr == 0x5205 ->
        put_state(bus, :mul_a, val)

      addr == 0x5206 ->
        put_state(bus, :mul_b, val)

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

  def read(%{mapper: 5} = bus, 0x5205),
    do: {bus.mapper_state.mul_a * bus.mapper_state.mul_b &&& 0xFF, bus}

  def read(%{mapper: 5} = bus, 0x5206),
    do: {(bus.mapper_state.mul_a * bus.mapper_state.mul_b) >>> 8 &&& 0xFF, bus}

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
    latch = bus.mapper_state.irq_latch

    bus
    |> put_state(:irq_counter, sl)
    |> Map.put(:irq_pending, bus.irq_pending or (sl == latch and latch != 0))
  end

  # Recompute all PRG windows whenever the mode or a bank register changes.
  # $5113 always maps RAM at $6000. $5114-$5116 select RAM with bit 7 clear and
  # ROM with it set; $5117 is forced to ROM so vectors can never point into RAM.
  defp apply_mmc5_prg(bus) do
    ms = bus.mapper_state
    {ram6000, r14, r15, r16, r17} = ms.m5_prg_regs

    controls =
      case ms.prg_mode do
        3 -> [{r14, 0, 1, false}, {r15, 0, 1, false}, {r16, 0, 1, false}, {r17, 0, 1, true}]
        2 -> [{r15, 0, 2, false}, {r15, 1, 2, false}, {r16, 0, 1, false}, {r17, 0, 1, true}]
        1 -> [{r15, 0, 2, false}, {r15, 1, 2, false}, {r17, 0, 2, true}, {r17, 1, 2, true}]
        0 -> [{r17, 0, 4, true}, {r17, 1, 4, true}, {r17, 2, 4, true}, {r17, 3, 4, true}]
      end

    {offsets, ram_windows} =
      controls
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {{reg, local, alignment, force_rom}, window}, {offsets, mask} ->
        bank = (reg &&& bnot(alignment - 1)) + local
        ram? = not force_rom and (reg &&& 0x80) == 0
        offset = if(ram?, do: ram_off(bus, bank), else: b(bus, bank &&& 0x7F))
        {[offset | offsets], if(ram?, do: mask ||| 1 <<< window, else: mask)}
      end)

    [a, b0, c0, d] = Enum.reverse(offsets)

    bus
    |> merge_state(%{
      wram_source: :ram,
      wram_enabled: true,
      wram_bank: ram6000 &&& 0x0F,
      prg_ram_windows: ram_windows
    })
    |> Map.put(:prg_banks, {a, b0, c0, d})
  end

  # $5120-$5127 sprite CHR → chr_regs 0-7; $5128-$512B background → chr_regs 8-11.
  defp chr_reg_index(addr) when addr in 0x5120..0x5127, do: addr - 0x5120
  defp chr_reg_index(addr), do: 8 + (addr - 0x5128)

  # Expand the CHR registers into two 8x1KB window sets per the CHR mode ($5101):
  # sprites from $5120-$5127, background from $5128-$512B (used in 8x16 mode).
  defp mmc5_chr(bus) do
    ms = bus.mapper_state
    sprite = for w <- 0..7, do: chr_off(bus, elem(ms.chr_regs, sprite_reg(ms.chr_mode, w)), w)
    bg = for w <- 0..7, do: chr_off(bus, elem(ms.chr_regs, 8 + bg_reg(ms.chr_mode, w)), w)
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
    ms = bus.mapper_state
    win = elem({8, 4, 2, 1}, ms.chr_mode)
    local = elem({w, w &&& 0x03, w &&& 0x01, 0}, ms.chr_mode)
    bank = reg ||| ms.chr_hi <<< 8
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

  def clock_irq(%{mapper: mapper} = bus, n) when mapper in [4, 118, 119] and n > 0,
    do: Enum.reduce(1..n, bus, fn _, b -> tick_mmc3_irq(b) end)

  def clock_irq(%{mapper: 5} = bus, n) when n > 0, do: mmc5_scanline(bus)

  def clock_irq(bus, _n), do: bus

  defp mmc1(bus, _addr, val) when (val &&& 0x80) != 0,
    do:
      apply_mmc1(
        merge_state(bus, %{
          shift: 0,
          shift_count: 0,
          ctrl: bus.mapper_state.ctrl ||| 0x0C
        })
      )

  defp mmc1(bus, addr, val) do
    ms = bus.mapper_state
    shift = ms.shift >>> 1 ||| (val &&& 1) <<< 4

    if ms.shift_count == 4 do
      bus = merge_state(bus, %{shift: 0, shift_count: 0})

      case addr >>> 13 &&& 0x03 do
        0 -> bus |> put_state(:ctrl, shift) |> apply_mmc1()
        1 -> bus |> put_state(:chr0, shift) |> apply_mmc1()
        2 -> bus |> put_state(:chr1, shift) |> apply_mmc1()
        3 -> bus |> put_state(:prg_reg, shift) |> apply_mmc1()
      end
    else
      merge_state(bus, %{shift: shift, shift_count: ms.shift_count + 1})
    end
  end

  defp apply_mmc1(bus) do
    ms = bus.mapper_state
    outer = if byte_size(bus.prg) > 0x40000, do: ms.chr0 &&& 0x10, else: 0

    {lo16, hi16} =
      if ms.submapper == 5 do
        # SEROM/SHROM: the 32 KiB PRG ROM is fixed; the serial register still
        # controls mirroring and CHR banking.
        {0, 1}
      else
        case ms.ctrl >>> 2 &&& 0x03 do
          m when m in [0, 1] ->
            p = outer + (ms.prg_reg &&& 0x0E)
            {p, p + 1}

          2 ->
            {outer, outer + (ms.prg_reg &&& 0x0F)}

          3 ->
            {outer + (ms.prg_reg &&& 0x0F), min(outer + 0x0F, banks16(bus) - 1)}
        end
      end

    {clo, chi} =
      if (ms.ctrl &&& 0x10) == 0 do
        c = ms.chr0 &&& 0x1E
        {c, c + 1}
      else
        {ms.chr0, ms.chr1}
      end

    ram_size = max(ms.prg_ram_size, 0x2000)

    ram_bank =
      cond do
        ram_size >= 0x8000 -> (ms.chr0 >>> 3 &&& 1) ||| (ms.chr0 >>> 2 &&& 1) <<< 1
        ram_size >= 0x4000 -> ms.chr0 >>> 3 &&& 1
        true -> 0
      end

    bus =
      merge_state(bus, %{
        wram_source: :ram,
        wram_enabled: (ms.prg_reg &&& 0x10) == 0,
        wram_writable: true,
        wram_bank: ram_bank
      })

    bus
    |> set_prg([b(bus, lo16 * 2), b(bus, lo16 * 2 + 1), b(bus, hi16 * 2), b(bus, hi16 * 2 + 1)])
    |> set_chr(chr4(bus, clo) ++ chr4(bus, chi))
    |> mirror(mmc1_mirror(ms.ctrl &&& 0x03))
  end

  defp mmc1_mirror(0), do: :single0
  defp mmc1_mirror(1), do: :single1
  defp mmc1_mirror(2), do: :vertical
  defp mmc1_mirror(3), do: :horizontal

  # --- MMC3: 8 bank registers + scanline IRQ ---

  defp mmc3(bus, addr, val) do
    case {addr &&& 0xE001, val} do
      {0x8000, v} ->
        apply_mmc3(mmc3_bank_select(bus, v))

      {0x8001, v} ->
        ms = bus.mapper_state
        bus |> put_state(:regs, put_elem(ms.regs, ms.bank_select &&& 0x07, v)) |> apply_mmc3()

      {0xA000, _v} when bus.mapper == 118 ->
        # TxSROM wires CIRAM A10 to CHR A17, bypassing this MMC3 output.
        bus

      {0xA000, v} ->
        mirror(bus, if((v &&& 1) == 0, do: :vertical, else: :horizontal))

      {0xA001, v} ->
        mmc3_ram_control(bus, v)

      {0xC000, v} ->
        put_state(bus, :irq_latch, v)

      {0xC001, _} ->
        put_state(bus, :irq_reload, true)

      {0xE000, _} ->
        %{bus | irq_enabled: false, irq_pending: false}

      {0xE001, _} ->
        %{bus | irq_enabled: true}

      _ ->
        bus
    end
  end

  defp mmc3_bank_select(%{mapper_state: %{submapper: 1} = ms} = bus, val) do
    enabled = (val &&& 0x20) != 0

    merge_state(bus, %{
      bank_select: val,
      mmc6_ram_enabled: enabled,
      mmc6_read_mask: if(enabled, do: ms.mmc6_read_mask, else: 0),
      mmc6_write_mask: if(enabled, do: ms.mmc6_write_mask, else: 0)
    })
  end

  defp mmc3_bank_select(bus, val), do: put_state(bus, :bank_select, val)

  # MMC6 (NES 2.0 mapper 4 submapper 1) has two independently protected 512B
  # RAM halves. Reads/writes are also globally gated by $8000 bit 5.
  defp mmc3_ram_control(
         %{mapper_state: %{submapper: 1, mmc6_ram_enabled: false}} = bus,
         _val
       ),
       do: bus

  defp mmc3_ram_control(%{mapper_state: %{submapper: 1}} = bus, val) do
    merge_state(bus, %{
      mmc6_read_mask: (val >>> 5 &&& 1) ||| (val >>> 6 &&& 1) <<< 1,
      mmc6_write_mask: (val >>> 4 &&& 1) ||| (val >>> 5 &&& 2)
    })
  end

  defp mmc3_ram_control(bus, val) do
    merge_state(bus, %{
      wram_source: :ram,
      wram_enabled: (val &&& 0x80) != 0,
      wram_writable: (val &&& 0x40) == 0
    })
  end

  defp apply_mmc3(bus) do
    ms = bus.mapper_state
    r = ms.regs
    last = banks8(bus) - 1

    prg =
      if (ms.bank_select &&& 0x40) == 0 do
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
    chr = if (ms.bank_select &&& 0x80) == 0, do: lo ++ hi, else: hi ++ lo

    bus
    |> set_prg(Enum.map(prg, &b(bus, &1)))
    |> set_chr(Enum.map(chr, &mmc3_chr_bank(bus, &1)))
    |> apply_txsrom_mirroring()
  end

  # TQROM uses CHR bank bit 6 as the chip select. Negative bank offsets encode
  # its 8KB CHR RAM windows without adding another field to the hot PPU struct.
  defp mmc3_chr_bank(%{mapper: 119}, bank) when (bank &&& 0x40) != 0,
    do: -(rem(bank &&& 0x07, 8) * 0x400) - 1

  defp mmc3_chr_bank(%{mapper: 119} = bus, bank), do: c(bus, bank &&& 0x3F)
  defp mmc3_chr_bank(bus, bank), do: c(bus, bank)

  defp apply_txsrom_mirroring(%{mapper: 118} = bus) do
    ms = bus.mapper_state
    r = ms.regs

    sources =
      if (ms.bank_select &&& 0x80) == 0 do
        {elem(r, 0) >>> 7, elem(r, 0) >>> 7, elem(r, 1) >>> 7, elem(r, 1) >>> 7}
      else
        {elem(r, 2) >>> 7, elem(r, 3) >>> 7, elem(r, 4) >>> 7, elem(r, 5) >>> 7}
      end

    %{bus | ppu: %{bus.ppu | nt_source: sources}}
  end

  defp apply_txsrom_mirroring(bus), do: bus

  # --- Namco 108 / DxROM (mapper 206) ---

  defp namco108(bus, addr, val) when addr in 0x8000..0x9FFF and (addr &&& 1) == 0,
    do: put_state(bus, :bank_select, val &&& 0x07)

  defp namco108(bus, addr, val) when addr in 0x8000..0x9FFF do
    ms = bus.mapper_state
    reg = ms.bank_select

    val =
      cond do
        reg in [0, 1] -> val &&& 0x3E
        reg in 2..5 -> val &&& 0x3F
        true -> val &&& 0x0F
      end

    bus |> put_state(:regs, put_elem(ms.regs, reg, val)) |> apply_namco108()
  end

  defp namco108(bus, _addr, _val), do: bus

  defp apply_namco108(bus) do
    r = bus.mapper_state.regs
    last = banks8(bus) - 1

    chr = [
      elem(r, 0),
      elem(r, 0) + 1,
      elem(r, 1),
      elem(r, 1) + 1,
      elem(r, 2),
      elem(r, 3),
      elem(r, 4),
      elem(r, 5)
    ]

    bus
    |> set_prg(Enum.map([elem(r, 6), elem(r, 7), last - 1, last], &b(bus, &1)))
    |> set_chr(Enum.map(chr, &c(bus, &1)))
  end

  defp tick_mmc3_irq(bus) do
    ms = bus.mapper_state

    counter =
      if ms.irq_counter == 0 or ms.irq_reload, do: ms.irq_latch, else: ms.irq_counter - 1

    pending = bus.irq_pending or (counter == 0 and bus.irq_enabled)

    bus
    |> merge_state(%{irq_counter: counter, irq_reload: false})
    |> Map.put(:irq_pending, pending)
  end

  # --- FME-7 (Sunsoft): command/parameter ports + a CPU-cycle IRQ ---
  # $8000 latches which internal register; $A000 writes its parameter.

  defp fme7(bus, addr, val) when addr in 0x8000..0x9FFF,
    do: put_state(bus, :fme_cmd, val &&& 0x0F)

  defp fme7(bus, addr, val) when addr in 0xA000..0xBFFF,
    do: fme7_param(bus, bus.mapper_state.fme_cmd, val)

  defp fme7(bus, _addr, _val), do: bus

  # Regs 0-7: 1KB CHR banks. 9/A/B: 8KB PRG at $8000/$A000/$C000. C: mirroring.
  # D: IRQ control (bit0 count enable, bit7 IRQ enable; also acks). E/F: counter.
  defp fme7_param(bus, cmd, val) when cmd in 0..7, do: set_chr_window(bus, cmd, c(bus, val))
  defp fme7_param(bus, 8, val), do: fme7_wram(bus, val)
  defp fme7_param(bus, 9, val), do: set_prg_window(bus, 0, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 10, val), do: set_prg_window(bus, 1, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 11, val), do: set_prg_window(bus, 2, b(bus, val &&& 0x3F))
  defp fme7_param(bus, 12, val), do: mirror(bus, fme7_mirror(val &&& 0x03))

  defp fme7_param(bus, 13, val),
    do:
      bus
      |> put_state(:fme_count_on, (val &&& 1) != 0)
      |> Map.merge(%{irq_enabled: (val &&& 0x80) != 0, irq_pending: false})

  defp fme7_param(bus, 14, val),
    do: put_state(bus, :irq_counter, (bus.mapper_state.irq_counter &&& 0xFF00) ||| val)

  defp fme7_param(bus, 15, val),
    do: put_state(bus, :irq_counter, (bus.mapper_state.irq_counter &&& 0x00FF) ||| val <<< 8)

  defp fme7_param(bus, _cmd, _val), do: bus

  defp fme7_wram(bus, val) do
    ram? = (val &&& 0x40) != 0

    merge_state(bus, %{
      wram_source: if(ram?, do: :ram, else: :rom),
      wram_enabled: not ram? or (val &&& 0x80) != 0,
      wram_writable: ram? and (val &&& 0x80) != 0,
      wram_bank: val &&& 0x3F
    })
  end

  defp fme7_mirror(0), do: :vertical
  defp fme7_mirror(1), do: :horizontal
  defp fme7_mirror(2), do: :single0
  defp fme7_mirror(3), do: :single1

  # FME-7's 16-bit down-counter is clocked every CPU cycle; underflow raises IRQ.
  def clock_cpu_irq(%{mapper: 69} = bus, n) when n > 0,
    do: Enum.reduce(1..n, bus, fn _, b -> fme7_tick(b) end)

  def clock_cpu_irq(bus, _n), do: bus

  defp fme7_tick(%{mapper_state: %{fme_count_on: false}} = bus), do: bus

  defp fme7_tick(%{mapper_state: %{irq_counter: 0}} = bus),
    do:
      bus
      |> put_state(:irq_counter, 0xFFFF)
      |> Map.put(:irq_pending, bus.irq_pending or bus.irq_enabled)

  defp fme7_tick(bus), do: put_state(bus, :irq_counter, bus.mapper_state.irq_counter - 1)

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

  defp ram_off(bus, bank),
    do: rem(bank * 0x2000, max(bus.mapper_state.prg_ram_size, 0x2000))

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
