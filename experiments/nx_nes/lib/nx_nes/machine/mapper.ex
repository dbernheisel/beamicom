defmodule NxNes.Machine.Mapper do
  @moduledoc "Resident MMC5 banking, ExRAM, multiplier and scanline IRQ control."
  import Nx.Defn
  alias NxNes.Machine.PPU

  defn write(s, a, v) do
    m = s.mapper
    p = s.ppu
    # Balanced address dispatch keeps StableHLO lowering off deep recursive paths.
    if a < 0x5120 do
      if a < 0x5104 do
        if a < 0x5102 do
          if a < 0x5101 do
            if a == 0x5100, do: prg(%{s | mapper: %{m | prg_mode: band(v, 3)}}), else: s
          else
            if a == 0x5101, do: chr(%{s | mapper: %{m | chr_mode: band(v, 3)}}), else: s
          end
        else
          if a < 0x5103 do
            if a == 0x5102, do: %{s | mapper: %{m | m5_protect1: band(v, 3)}}, else: s
          else
            if a == 0x5103, do: %{s | mapper: %{m | m5_protect2: band(v, 3)}}, else: s
          end
        end
      else
        if a < 0x5106 do
          if a < 0x5105 do
            if a == 0x5104, do: %{s | ppu: %{p | exram_mode: band(v, 3)}}, else: s
          else
            if a == 0x5105,
              do: %{
                s
                | ppu: %{p | nt_source: band(Nx.right_shift(v, Nx.iota({4}, type: :s32) * 2), 3)}
              },
              else: s
          end
        else
          if a < 0x5107 do
            if a == 0x5106, do: %{s | ppu: %{p | fill_tile: v}}, else: s
          else
            if a < 0x5113 do
              if a == 0x5107, do: %{s | ppu: %{p | fill_attr: band(v, 3)}}, else: s
            else
              if a >= 0x5113 and a <= 0x5117,
                do: prg(%{s | mapper: %{m | m5_prg_regs: PPU.put(m.m5_prg_regs, a - 0x5113, v)}}),
                else: s
            end
          end
        end
      end
    else
      if a < 0x5203 do
        if a < 0x5200 do
          if a < 0x5130 do
            if a >= 0x5120 and a <= 0x512B,
              do: chr(%{s | mapper: %{m | chr_regs: PPU.put(m.chr_regs, a - 0x5120, v)}}),
              else: s
          else
            if a == 0x5130,
              do:
                chr(%{s | mapper: %{m | chr_hi: band(v, 3)}, ppu: %{p | ext_chr_hi: band(v, 3)}}),
              else: s
          end
        else
          if a < 0x5201 do
            if a == 0x5200,
              do: %{
                s
                | ppu: %{
                    p
                    | split_en: Nx.as_type(band(v, 128) != 0, :s32),
                      split_side: band(Nx.right_shift(v, 6), 1),
                      split_tile: band(v, 31)
                  }
              },
              else: s
          else
            if a < 0x5202 do
              if a == 0x5201, do: %{s | ppu: %{p | split_scroll: v}}, else: s
            else
              if a == 0x5202, do: %{s | ppu: %{p | split_chr: v}}, else: s
            end
          end
        end
      else
        if a < 0x5205 do
          if a < 0x5204 do
            if a == 0x5203, do: %{s | mapper: %{m | irq_latch: v}}, else: s
          else
            if a == 0x5204, do: %{s | irq_enabled: Nx.as_type(band(v, 128) != 0, :s32)}, else: s
          end
        else
          if a < 0x5206 do
            if a == 0x5205, do: %{s | mapper: %{m | mul_a: v}}, else: s
          else
            if a < 0x5C00 do
              if a == 0x5206, do: %{s | mapper: %{m | mul_b: v}}, else: s
            else
              if a >= 0x5C00 and a <= 0x5FFF,
                do: %{s | ppu: %{p | exram: PPU.put(p.exram, a - 0x5C00, v)}},
                else: s
            end
          end
        end
      end
    end
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
end
