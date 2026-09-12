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

  # CPU dispatch returns at most three byte writes (BRK/interrupt stack pushes).
  # Commit only after the whole instruction passes its deadline/device checks.
  deftransform write(s, addr, value) do
    if Map.has_key?(s, :write_count),
      do: queue_write(s, addr, value),
      else: direct_write(s, addr, value)
  end

  defn queue_write(s, addr, value) do
    a = band(addr, 65535)

    if a >= 0x2000 and a < 0x6000 do
      Bus.barrier(s, 3, a, band(value, 255))
    else
      n = s.write_count

      %{
        s
        | write_count: n + 1,
          write_addr0: Nx.select(n == 0, a, s.write_addr0),
          write_addr1: Nx.select(n == 1, a, s.write_addr1),
          write_addr2: Nx.select(n == 2, a, s.write_addr2),
          write_value0: Nx.select(n == 0, value, s.write_value0),
          write_value1: Nx.select(n == 1, value, s.write_value1),
          write_value2: Nx.select(n == 2, value, s.write_value2)
      }
    end
  end

  defn commit(s) do
    s = if s.write_count > 0, do: direct_write(s, s.write_addr0, s.write_value0), else: s
    s = if s.write_count > 1, do: direct_write(s, s.write_addr1, s.write_value1), else: s
    s = if s.write_count > 2, do: direct_write(s, s.write_addr2, s.write_value2), else: s
    %{s | write_count: Nx.tensor(0, type: :s32)}
  end

  defn direct_write(s, addr, value) do
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
