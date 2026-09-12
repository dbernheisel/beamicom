defmodule NxNes.Machine.Bus do
  @moduledoc "MMC5 CPU bus with tensor device access; no host callbacks."
  import Nx.Defn
  alias NxNes.Machine.{PPU, Mapper, Audio}

  defn peek(s, address) do
    a = band(address, 65535)
    w = Nx.clip(Nx.right_shift(a - 32768, 13), 0, 3)
    off = s.prg_banks[w] + band(a, 8191)
    rom = Nx.as_type(s.prg[Nx.remainder(off, Nx.axis_size(s.prg, 0))], :s32)
    upper_ram = Nx.as_type(s.wram[Nx.remainder(off, Nx.axis_size(s.wram, 0))], :s32)
    upper = Nx.select(band(s.mapper.prg_ram_windows, Nx.left_shift(1, w)) != 0, upper_ram, rom)

    low_ram =
      Nx.as_type(
        s.wram[Nx.remainder(s.mapper.wram_bank * 8192 + band(a, 8191), Nx.axis_size(s.wram, 0))],
        :s32
      )

    ex = Nx.select(a >= 0x5C00 and s.ppu.exram_mode >= 2, s.ppu.exram[band(a, 1023)], 0)

    Nx.select(
      a < 8192,
      Nx.as_type(s.ram[band(a, 2047)], :s32),
      Nx.select(a >= 32768, upper, Nx.select(a >= 24576, low_ram, ex))
    )
  end

  defn read(s, a) do
    if a < 0x2000 or a >= 0x6000, do: {peek(s, a), s}, else: device_read(s, a)
  end

  defnp device_read(s, a) do
    cond do
      a >= 0x2000 and a <= 0x3FFF ->
        {v, p} = PPU.read_register(s.ppu, s.chr, a)
        {v, %{s | ppu: p}}

      a == 0x4016 or a == 0x4017 ->
        buttons = Nx.select(a == 0x4016, s.pad1, s.pad2)
        index = Nx.select(a == 0x4016, s.pad1_index, s.pad2_index)
        bit = Nx.select(index < 8, band(Nx.right_shift(buttons, Nx.min(index, 7)), 1), 1)
        v = Nx.select(s.strobe != 0, band(buttons, 1), bit)
        index = Nx.select(s.strobe != 0, index, Nx.min(index + 1, 8))

        {v,
         %{
           s
           | pad1_index: Nx.select(a == 0x4016, index, s.pad1_index),
             pad2_index: Nx.select(a == 0x4017, index, s.pad2_index)
         }}

      a == 0x4015 ->
        s = Audio.sync(s)

        v =
          Nx.select(s.apu.pulse1.length > 0, 1, 0) + Nx.select(s.apu.pulse2.length > 0, 2, 0) +
            Nx.select(s.apu.triangle.length > 0, 4, 0) + Nx.select(s.apu.noise.length > 0, 8, 0) +
            Nx.select(s.apu.frame_irq != 0, 64, 0)

        {v, %{s | apu: %{s.apu | frame_irq: Nx.tensor(0, type: :s32)}}}

      a >= 0x5000 and a <= 0x5FFF ->
        Mapper.read(s, a)

      true ->
        {peek(s, a), s}
    end
  end

  defn write(s, address, value) do
    a = band(address, 65535)
    v = band(value, 255)

    if a < 0x4000 do
      cond do
        a < 0x2000 -> %{s | ram: PPU.put(s.ram, band(a, 2047), v)}
        a <= 0x3FFF -> %{s | ppu: PPU.write_register(s.ppu, a, v)}
        true -> s
      end
    else
      if a >= 0x6000 do
        cond do
          a >= 0x6000 and a <= 0x7FFF ->
            %{
              s
              | wram:
                  PPU.put(
                    s.wram,
                    Nx.remainder(
                      s.mapper.wram_bank * 8192 + band(a, 8191),
                      Nx.axis_size(s.wram, 0)
                    ),
                    v
                  )
            }

          a >= 0x8000 ->
            w = Nx.right_shift(a - 32768, 13)

            if band(s.mapper.prg_ram_windows, Nx.left_shift(1, w)) != 0 and
                 s.mapper.m5_protect1 == 2 and s.mapper.m5_protect2 == 1 do
              %{
                s
                | wram:
                    PPU.put(
                      s.wram,
                      Nx.remainder(s.prg_banks[w] + band(a, 8191), Nx.axis_size(s.wram, 0)),
                      v
                    )
              }
            else
              s
            end

          true ->
            s
        end
      else
        cond do
          a == 0x4014 ->
            i = Nx.iota({256}, type: :s32)
            bytes = Nx.as_type(peek(s, v * 256 + band(i - s.ppu.oam_addr, 255)), :u8)
            %{s | ppu: %{s.ppu | oam: Nx.reshape(bytes, {64, 4})}, dma: Nx.tensor(1, type: :s32)}

          a == 0x4016 ->
            strobe = band(v, 1)

            %{
              s
              | strobe: strobe,
                pad1_index: Nx.select(strobe != 0, 0, s.pad1_index),
                pad2_index: Nx.select(strobe != 0, 0, s.pad2_index)
            }

          (a >= 0x4000 and a <= 0x4013) or a == 0x4015 or a == 0x4017 or
              (a >= 0x5000 and a <= 0x5015) ->
            s = Audio.sync(s)
            # Explicitly reject enabling DMC; this workload does not use it.
            reason = Nx.select(a == 0x4015 and band(v, 16) != 0, 7, s.reason)
            %{s | apu: NxNes.APUWrites.apply(s.apu, a, v), reason: reason}

          a >= 0x4020 and a <= 0x5FFF ->
            Mapper.write(s, a, v)

          true ->
            s
        end
      end
    end
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
end
