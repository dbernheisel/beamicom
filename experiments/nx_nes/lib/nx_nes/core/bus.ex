defmodule NxNes.Core.Bus do
  @moduledoc "Resident NROM CPU memory and controllers. Device accesses produce explicit transactional barriers."
  import Nx.Defn

  deftransform(peek(s, addr),
    do:
      if(Map.has_key?(s, :prg_banks),
        do: NxNes.Machine.Memory.peek(s, addr),
        else: nrom_peek(s, addr)
      )
  )

  deftransform(read(s, addr),
    do:
      if(Map.has_key?(s, :prg_banks),
        do: NxNes.Machine.Memory.read(s, addr),
        else: nrom_read(s, addr)
      )
  )

  deftransform(write(s, addr, value),
    do:
      if(Map.has_key?(s, :prg_banks),
        do: NxNes.Machine.Memory.write(s, addr, value),
        else: nrom_write(s, addr, value)
      )
  )

  defn nrom_peek(s, addr) do
    a = Nx.bitwise_and(addr, 65535)
    ram = Nx.as_type(Nx.take(s.ram, Nx.bitwise_and(a, 2047)), :s32)
    rom = Nx.as_type(Nx.take(s.prg, Nx.bitwise_and(a - 32768, s.prg_mask)), :s32)
    wram = Nx.as_type(Nx.take(s.wram, Nx.bitwise_and(a, 8191)), :s32)
    Nx.select(a < 8192, ram, Nx.select(a >= 32768, rom, Nx.select(a >= 24576, wram, 0)))
  end

  defn nrom_read(s, addr) do
    cond do
      s.io_read_ready != 0 and s.io_read_addr == addr ->
        {s.io_read_value, s}

      addr == 0x4016 ->
        {v, index} = pad(s.pad1, s.pad1_index, s.strobe)
        {v, %{s | pad1_index: index}}

      addr == 0x4017 ->
        {v, index} = pad(s.pad2, s.pad2_index, s.strobe)
        {v, %{s | pad2_index: index}}

      addr >= 0x2000 and addr < 0x6000 ->
        {Nx.tensor(0, type: :s32), barrier(s, 2, addr, 0)}

      true ->
        {peek(s, addr), s}
    end
  end

  defn nrom_write(s, addr, value) do
    a = Nx.bitwise_and(addr, 65535)
    v = Nx.bitwise_and(value, 255)

    cond do
      s.io_write_ready != 0 and s.io_write_addr == a ->
        s

      a < 0x2000 ->
        %{
          s
          | ram:
              Nx.put_slice(s.ram, [Nx.bitwise_and(a, 2047)], Nx.reshape(Nx.as_type(v, :u8), {1}))
        }

      a >= 0x6000 and a < 0x8000 ->
        %{s | wram: Nx.put_slice(s.wram, [a - 0x6000], Nx.reshape(Nx.as_type(v, :u8), {1}))}

      a == 0x4016 ->
        strobe = Nx.bitwise_and(v, 1)

        %{
          s
          | strobe: strobe,
            pad1_index: Nx.select(strobe != 0, 0, s.pad1_index),
            pad2_index: Nx.select(strobe != 0, 0, s.pad2_index)
        }

      a >= 0x8000 ->
        s

      true ->
        barrier(s, 3, a, v)
    end
  end

  defn barrier(s, reason, addr, value) do
    %{
      s
      | reason: Nx.select(s.reason == 0, reason, s.reason),
        event_addr: Nx.select(s.reason == 0, addr, s.event_addr),
        event_value: Nx.select(s.reason == 0, value, s.event_value)
    }
  end

  defnp pad(buttons, index, strobe) do
    bit = Nx.select(index < 8, Nx.bitwise_and(Nx.right_shift(buttons, Nx.min(index, 7)), 1), 1)

    {Nx.select(strobe != 0, Nx.bitwise_and(buttons, 1), bit),
     Nx.select(strobe != 0, index, Nx.min(index + 1, 8))}
  end
end
