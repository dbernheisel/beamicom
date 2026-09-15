defmodule Beamicom.NES.Recompiler.EquivalenceTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Bus, CPU, Console}
  alias Beamicom.NES.Recompiler.Equivalence

  defp console(program) do
    prg = program <> :binary.copy(<<0xEA>>, 0x4000 - byte_size(program))

    bus = %Bus{
      ram: <<0::size(0x800 * 8)>>,
      wram: %{},
      prg: prg,
      prg_banks: {0, 0x2000, 0, 0x2000},
      mapper: 0
    }

    %Console{cpu: %CPU{pc: 0x8000, cycles: 7}, bus: bus}
  end

  test "accepts the interpreter as a one-instruction candidate" do
    start = console(<<0xA9, 0x7F, 0xAA, 0xE8>>)
    candidate = fn state -> {Console.step(state), 1} end

    assert {:ok, result} = Equivalence.compare_many(start, candidate, 3)
    assert result.cpu.a == 0x7F
    assert result.cpu.x == 0x80
    assert result.cpu.cycles == 13
  end

  test "compares a whole candidate block with the same number of oracle steps" do
    start = console(<<0xA9, 0x2A, 0x85, 0x10, 0xE8>>)

    candidate = fn state ->
      state = state |> Console.step() |> Console.step()
      {state, 2}
    end

    assert {:ok, result} = Equivalence.compare(start, candidate)
    assert :binary.at(result.bus.ram, 0x10) == 0x2A
  end

  test "reports the first mismatching field and both snapshots" do
    start = console(<<0xE8>>)

    candidate = fn state ->
      state = Console.step(state)
      {%{state | cpu: %{state.cpu | x: 0x55}}, 1}
    end

    assert {:error, mismatch} = Equivalence.compare(start, candidate)
    assert mismatch.start_pc == 0x8000
    assert mismatch.difference.field == :cpu
    assert mismatch.expected.cpu.x == 1
    assert mismatch.actual.cpu.x == 0x55
    assert mismatch.expected.ram == mismatch.actual.ram
  end

  test "opcode metadata is defined for every byte" do
    assert Enum.all?(0..255, fn opcode ->
             {operation, mode, cycles} = CPU.opcode_info(opcode)
             is_atom(operation) and is_atom(mode) and is_integer(cycles) and cycles > 0
           end)
  end
end
