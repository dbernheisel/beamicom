defmodule NxNes.QueuedCPUTest do
  use ExUnit.Case, async: false
  alias NxNes.Core.{CPU, Decode}
  alias NxNes.Machine.Memory

  test "queued writes preserve every opcode and roll back at deadlines" do
    direct = EXLA.jit(&CPU.step/2)
    queued = EXLA.jit(&CPU.step/2)

    for opcode <- Decode.supported(), sp <- [0, 255] do
      s = state(opcode, sp)
      q = queue(s)
      expected = direct.(s, Nx.tensor(1000, type: :s64))
      actual = queued.(q, Nx.tensor(1000, type: :s64))
      compare(actual, expected)
      assert Nx.to_number(actual.write_count) == 0
      # Includes BRK's three writes, JSR's two, and single-byte/RMW writes.
      if Nx.to_number(expected.reason) == 0 do
        deadline = Nx.to_number(expected.cycles) - 1
        actual = queued.(q, Nx.tensor(deadline, type: :s64))
        compare(actual, direct.(s, Nx.tensor(deadline, type: :s64)))
        assert Nx.to_binary(actual.ram) == Nx.to_binary(s.ram)
        assert Nx.to_binary(actual.wram) == Nx.to_binary(s.wram)
      end
    end
  end

  test "interrupt stack writes commit in order or roll back together" do
    direct = EXLA.jit(&CPU.interrupt/3)
    queued = EXLA.jit(fn s, kind, deadline -> Memory.commit(CPU.interrupt(s, kind, deadline)) end)
    s = state(0xEA, 0)

    for kind <- [1, 2], deadline <- [13, 14] do
      compare(
        queued.(queue(s), Nx.tensor(kind), Nx.tensor(deadline, type: :s64)),
        direct.(s, Nx.tensor(kind), Nx.tensor(deadline, type: :s64))
      )
    end
  end

  defp compare(actual, expected) do
    for key <- [
          :a,
          :x,
          :y,
          :sp,
          :p,
          :pc,
          :cycles,
          :ram,
          :wram,
          :reason,
          :event_addr,
          :event_value,
          :event_cycle
        ] do
      assert Nx.to_binary(actual[key]) == Nx.to_binary(expected[key]), "mismatch: #{key}"
    end
  end

  defp state(opcode, sp) do
    prg = <<opcode, 0x30, 0x60>> <> :binary.copy(<<0xEA>>, 32765)
    media = <<"NES", 26, 2, 1, 0::80>> <> prg <> :binary.copy(<<0>>, 8192)
    {:ok, s} = NxNes.Core.load(media, pc: 0x8000)

    extra = %{
      prg_banks: Nx.tensor([0, 8192, 16384, 24576]),
      wram_bank: Nx.tensor(0),
      prg_ram_windows: Nx.tensor(0),
      wram_writable: Nx.tensor(1),
      exram: Nx.broadcast(Nx.tensor(0), {1024}),
      exram_mode: Nx.tensor(0),
      sp: Nx.tensor(sp),
      a: Nx.tensor(127),
      x: Nx.tensor(3),
      y: Nx.tensor(7),
      p: Nx.tensor(0x21)
    }

    Map.merge(s, extra) |> Nx.backend_copy({EXLA.Backend, client: :host})
  end

  defp queue(s) do
    fields =
      for key <- [
            :write_count,
            :write_addr0,
            :write_addr1,
            :write_addr2,
            :write_value0,
            :write_value1,
            :write_value2
          ],
          into: %{},
          do: {key, Nx.tensor(0, type: :s32)}

    Map.merge(s, fields)
  end
end
