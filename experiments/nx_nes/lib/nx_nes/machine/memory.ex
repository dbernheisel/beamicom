defmodule NxNes.Machine.Memory do
  @moduledoc false
  import Nx.Defn
  alias NxNes.Core.Bus

  defn peek(s, address) do
    a = band(address, 65535)
    w = Nx.clip(Nx.right_shift(a - 32768, 13), 0, 3)
    off = s.prg_banks[w] + band(a, 8191)
    rom = Nx.as_type(s.prg[Nx.remainder(off, Nx.axis_size(s.prg, 0))], :s32)
    upper_ram = Nx.as_type(s.wram[Nx.remainder(off, Nx.axis_size(s.wram, 0))], :s32)
    upper = Nx.select(band(s.prg_ram_windows, Nx.left_shift(1, w)) != 0, upper_ram, rom)

    low_ram =
      Nx.as_type(
        s.wram[Nx.remainder(s.wram_bank * 8192 + band(a, 8191), Nx.axis_size(s.wram, 0))],
        :s32
      )

    ex = Nx.select(a >= 0x5C00 and s.exram_mode >= 2, s.exram[band(a, 1023)], 0)

    Nx.select(
      a < 8192,
      Nx.as_type(s.ram[band(a, 2047)], :s32),
      Nx.select(a >= 32768, upper, Nx.select(a >= 24576, low_ram, ex))
    )
  end

  defn read(s, a) do
    cond do
      s.io_read_ready != 0 and s.io_read_addr == a -> {s.io_read_value, s}
      a >= 0x2000 and a < 0x6000 -> {Nx.tensor(0, type: :s32), Bus.barrier(s, 2, a, 0)}
      true -> {peek(s, a), s}
    end
  end

  defn write(s, addr, value) do
    a = band(addr, 65535)
    v = band(value, 255)

    cond do
      a < 0x2000 ->
        %{s | ram: put(s.ram, band(a, 2047), v)}

      a >= 0x6000 and a <= 0x7FFF ->
        %{
          s
          | wram:
              put(
                s.wram,
                Nx.remainder(s.wram_bank * 8192 + band(a, 8191), Nx.axis_size(s.wram, 0)),
                v
              )
        }

      a >= 0x8000 ->
        w = Nx.right_shift(a - 32768, 13)

        if band(s.prg_ram_windows, Nx.left_shift(1, w)) != 0 and s.wram_writable != 0 do
          %{
            s
            | wram:
                put(
                  s.wram,
                  Nx.remainder(s.prg_banks[w] + band(a, 8191), Nx.axis_size(s.wram, 0)),
                  v
                )
          }
        else
          s
        end

      true ->
        Bus.barrier(s, 3, a, v)
    end
  end

  defnp(put(t, i, v), do: Nx.put_slice(t, [i], Nx.reshape(Nx.as_type(v, :u8), {1})))
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
end
