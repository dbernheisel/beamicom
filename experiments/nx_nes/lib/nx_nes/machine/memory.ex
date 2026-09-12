defmodule NxNes.Machine.Memory do
  @moduledoc false
  import Nx.Defn
  alias NxNes.Core.Bus
  @journal_capacity 8

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

    base =
      Nx.select(
        a < 8192,
        Nx.as_type(s.ram[band(a, 2047)], :s32),
        Nx.select(a >= 32768, upper, Nx.select(a >= 24576, low_ram, ex))
      )

    if a < 0x2000, do: maybe_journal_read(s, a, base), else: base
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

  deftransform commit(s) do
    if Map.has_key?(s, :journal_count), do: commit_journal(s), else: commit_direct(s)
  end

  defn commit_journal(s) do
    s = if s.write_count > 0, do: commit_one(s, s.write_addr0, s.write_value0), else: s
    s = if s.write_count > 1, do: commit_one(s, s.write_addr1, s.write_value1), else: s
    s = if s.write_count > 2, do: commit_one(s, s.write_addr2, s.write_value2), else: s
    %{s | write_count: Nx.tensor(0, type: :s32)}
  end

  defn(journal_write(s, address, value), do: append(s, address, value))

  defn commit_direct(s) do
    s = if s.write_count > 0, do: direct_write(s, s.write_addr0, s.write_value0), else: s
    s = if s.write_count > 1, do: direct_write(s, s.write_addr1, s.write_value1), else: s
    s = if s.write_count > 2, do: direct_write(s, s.write_addr2, s.write_value2), else: s
    %{s | write_count: Nx.tensor(0, type: :s32)}
  end

  defn flush_journal(s) do
    {ram, _, _, _, _} =
      while {ram = s.ram, i = Nx.tensor(0, type: :s32), count = s.journal_count,
             keys = s.journal_keys, values = s.journal_values},
            i < count do
        key = keys[i]
        value = values[i]
        {put(ram, key, value), i + 1, count, keys, values}
      end

    %{s | ram: ram, journal_count: Nx.tensor(0, type: :s32)}
  end

  defn(journal_room(s), do: s.journal_count <= @journal_capacity - 3)
  defn(journal_room_for(s, needed), do: s.journal_count <= @journal_capacity - needed)

  defn journal_iterations(s, writes_per_iteration) do
    Nx.quotient(@journal_capacity - s.journal_count, writes_per_iteration)
  end

  defnp append(s, address, value) do
    a = Nx.bitwise_and(address, Nx.tensor(65535, type: :s32))
    key = Nx.remainder(a, Nx.tensor(2048, type: :s32))

    if a < 0x2000 do
      i = s.journal_count

      %{
        s
        | journal_keys: put_key(s.journal_keys, i, key),
          journal_values: put(s.journal_values, i, value),
          journal_count: i + 1
      }
    else
      s
    end
  end

  defnp commit_one(s, address, value) do
    if address < 0x2000, do: append(s, address, value), else: direct_write(s, address, value)
  end

  deftransform journal_read(s, key, base) do
    if Nx.rank(key) == 0 do
      journal_read_scalar(s, key, base)
    else
      shape = Nx.shape(key)
      journal_read_vector(s, key, base, shape: shape, size: Tuple.product(shape))
    end
  end

  defn journal_read_scalar(s, key, base) do
    indices = Nx.iota({@journal_capacity}, type: :s32)
    valid = indices < s.journal_count and s.journal_keys == key and key >= 0
    latest = Nx.reduce_max(Nx.select(valid, indices + 1, 0))
    value = Nx.as_type(s.journal_values[Nx.max(latest - 1, 0)], :s32)
    Nx.select(latest > 0, value, base)
  end

  defn journal_read_vector(s, key, base, opts \\ []) do
    shape = opts[:shape]
    size = opts[:size]
    indices = Nx.iota({@journal_capacity, 1}, type: :s32)
    keys = Nx.reshape(s.journal_keys, {@journal_capacity, 1})
    wanted = Nx.reshape(key, {1, size})
    valid = indices < s.journal_count and keys == wanted and wanted >= 0
    latest = Nx.reduce_max(Nx.select(valid, indices + 1, 0), axes: [0])
    values = Nx.as_type(Nx.take(s.journal_values, Nx.max(latest - 1, 0)), :s32)
    Nx.reshape(Nx.select(latest > 0, values, Nx.reshape(base, {size})), shape)
  end

  deftransformp maybe_journal_read(s, a, base) do
    if Map.has_key?(s, :journal_count), do: journal_read(s, physical_key(s, a), base), else: base
  end

  defnp(physical_key(_s, a), do: Nx.remainder(a, Nx.tensor(2048, type: :s32)))

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
  defnp(put_key(t, i, v), do: Nx.put_slice(t, [i], Nx.reshape(Nx.as_type(v, :s32), {1})))
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
end
