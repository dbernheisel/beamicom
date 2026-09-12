defmodule NxNes.Machine.Mapper do
  @moduledoc "Resident MMC5 banking, ExRAM, multiplier and scanline IRQ control."
  import Nx.Defn
  alias NxNes.Machine.PPU

  defn write(s, a, v) do
    m = s.mapper
    p = s.ppu
    prg_register = a >= 0x5113 and a <= 0x5117
    prg_index = Nx.clip(a - 0x5113, 0, 4)
    prg_old = m.m5_prg_regs[prg_index]

    prg_registers =
      PPU.put(m.m5_prg_regs, prg_index, Nx.select(prg_register, v, prg_old))

    chr_register = a >= 0x5120 and a <= 0x512B
    chr_index = Nx.clip(a - 0x5120, 0, 11)
    chr_old = m.chr_regs[chr_index]
    chr_registers = PPU.put(m.chr_regs, chr_index, Nx.select(chr_register, v, chr_old))
    exram_write = a >= 0x5C00 and a <= 0x5FFF
    exram_index = Nx.clip(a - 0x5C00, 0, 1023)
    exram_old = p.exram[exram_index]
    exram = PPU.put(p.exram, exram_index, Nx.select(exram_write, v, exram_old))

    next = %{
      s
      | irq_enabled: Nx.select(a == 0x5204, Nx.as_type(band(v, 128) != 0, :s32), s.irq_enabled),
        mapper: %{
          m
          | prg_mode: Nx.select(a == 0x5100, band(v, 3), m.prg_mode),
            chr_mode: Nx.select(a == 0x5101, band(v, 3), m.chr_mode),
            m5_protect1: Nx.select(a == 0x5102, band(v, 3), m.m5_protect1),
            m5_protect2: Nx.select(a == 0x5103, band(v, 3), m.m5_protect2),
            m5_prg_regs: prg_registers,
            chr_regs: chr_registers,
            chr_hi: Nx.select(a == 0x5130, band(v, 3), m.chr_hi),
            irq_latch: Nx.select(a == 0x5203, v, m.irq_latch),
            mul_a: Nx.select(a == 0x5205, v, m.mul_a),
            mul_b: Nx.select(a == 0x5206, v, m.mul_b)
        },
        ppu: %{
          p
          | exram_mode: Nx.select(a == 0x5104, band(v, 3), p.exram_mode),
            nt_source:
              Nx.select(
                a == 0x5105,
                band(Nx.right_shift(v, Nx.iota({4}, type: :s32) * 2), 3),
                p.nt_source
              ),
            fill_tile: Nx.select(a == 0x5106, v, p.fill_tile),
            fill_attr: Nx.select(a == 0x5107, band(v, 3), p.fill_attr),
            ext_chr_hi: Nx.select(a == 0x5130, band(v, 3), p.ext_chr_hi),
            split_en: Nx.select(a == 0x5200, Nx.as_type(band(v, 128) != 0, :s32), p.split_en),
            split_side: Nx.select(a == 0x5200, band(Nx.right_shift(v, 6), 1), p.split_side),
            split_tile: Nx.select(a == 0x5200, band(v, 31), p.split_tile),
            split_scroll: Nx.select(a == 0x5201, v, p.split_scroll),
            split_chr: Nx.select(a == 0x5202, v, p.split_chr),
            exram: exram
        }
    }

    prg_changed = a == 0x5100 or prg_register
    chr_changed = a == 0x5101 or chr_register or a == 0x5130
    next = select_state(prg_changed, prg(next), next)
    select_state(chr_changed, chr(next), next)
  end

  defn read(s, a) do
    cond do
      a == 0x5204 ->
        {Nx.select(s.irq_pending != 0, 128, 0) + Nx.select(s.ppu.scanline < 240, 64, 0),
         %{s | irq_pending: Nx.tensor(0, type: :s32)}}

      a == 0x5205 ->
        {band(s.mapper.mul_a * s.mapper.mul_b, 255), s}

      a == 0x5206 ->
        {band(Nx.right_shift(s.mapper.mul_a * s.mapper.mul_b, 8), 255), s}

      a >= 0x5C00 and a <= 0x5FFF and s.ppu.exram_mode >= 2 ->
        {s.ppu.exram[a - 0x5C00], s}

      true ->
        {Nx.tensor(0, type: :s32), s}
    end
  end

  defn prg(s) do
    m = s.mapper
    w = Nx.iota({4}, type: :s32)
    mode = m.prg_mode

    index =
      Nx.select(
        mode == 0,
        4,
        Nx.select(
          mode == 1,
          Nx.select(w < 2, 2, 4),
          Nx.select(mode == 2, Nx.select(w < 2, 2, w + 1), w + 1)
        )
      )

    alignment = Nx.select(mode == 0, 4, Nx.select(mode == 1 or (mode == 2 and w < 2), 2, 1))
    local = band(w, alignment - 1)
    reg = m.m5_prg_regs[index]
    bank = band(reg, Nx.bitwise_xor(alignment - 1, 255)) + local
    force_rom = mode == 0 or (mode == 1 and w >= 2) or w == 3
    ram = not force_rom and band(reg, 128) == 0

    offset =
      Nx.select(
        ram,
        Nx.remainder(bank * 8192, Nx.axis_size(s.wram, 0)),
        Nx.remainder(band(bank, 127) * 8192, Nx.axis_size(s.prg, 0))
      )

    mask = Nx.sum(Nx.select(ram, Nx.left_shift(1, w), 0))

    %{
      s
      | prg_banks: offset,
        mapper: %{m | wram_bank: band(m.m5_prg_regs[0], 15), prg_ram_windows: mask}
    }
  end

  defn chr(s) do
    m = s.mapper
    w = Nx.iota({8}, type: :s32)

    sr =
      Nx.select(
        m.chr_mode == 3,
        w,
        Nx.select(
          m.chr_mode == 2,
          Nx.bitwise_or(w, 1),
          Nx.select(m.chr_mode == 1, Nx.select(w < 4, 3, 7), 7)
        )
      )

    br =
      Nx.select(
        m.chr_mode == 3,
        band(w, 3),
        Nx.select(m.chr_mode == 2, Nx.select(band(w, 2) == 0, 1, 3), 3)
      )

    win = Nx.left_shift(1, 3 - m.chr_mode)
    local = band(w, win - 1)

    sprite =
      Nx.remainder(
        (Nx.bitwise_or(m.chr_regs[sr], m.chr_hi * 256) * win + local) * 1024,
        Nx.axis_size(s.chr, 0)
      )

    bg =
      Nx.remainder(
        (Nx.bitwise_or(m.chr_regs[8 + br], m.chr_hi * 256) * win + local) * 1024,
        Nx.axis_size(s.chr, 0)
      )

    %{s | ppu: %{s.ppu | chr_banks: sprite, bg_chr_banks: bg}}
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))

  deftransformp select_state(condition, candidate, state) do
    Map.new(state, fn {key, value} ->
      replacement = Map.fetch!(candidate, key)

      {key,
       if(is_map(value) and not is_struct(value, Nx.Tensor),
         do: select_state(condition, replacement, value),
         else: Nx.select(condition, replacement, value)
       )}
    end)
  end
end
