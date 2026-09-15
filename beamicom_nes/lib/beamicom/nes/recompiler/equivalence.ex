defmodule Beamicom.NES.Recompiler.Equivalence do
  @moduledoc """
  Differential oracle for alternative NES CPU execution paths.

  A candidate transition returns `{console, instruction_count}`. The oracle
  advances an immutable clone of the same starting console by exactly that many
  interpreter instructions, then compares CPU state and writable CPU memory.
  This shape supports both single-instruction candidates and basic blocks.
  """

  alias Beamicom.NES.{Console, CPU}

  @cpu_fields [
    :a,
    :x,
    :y,
    :sp,
    :pc,
    :p,
    :cycles,
    :nmi_prev,
    :nmi_edge,
    :nmi_pending
  ]

  @type candidate :: (Console.t() -> {Console.t(), pos_integer()})

  @doc "Run and compare one candidate transition."
  def compare(%Console{} = before, candidate) when is_function(candidate, 1) do
    case candidate.(before) do
      {%Console{} = actual, count} when is_integer(count) and count > 0 ->
        expected = run_interpreter(before, count)

        case difference(expected, actual) do
          nil ->
            {:ok, actual}

          diff ->
            {:error,
             %{
               instruction_count: count,
               start_pc: before.cpu.pc,
               expected: snapshot(expected),
               actual: snapshot(actual),
               difference: diff
             }}
        end

      other ->
        raise ArgumentError,
              "candidate must return {%Beamicom.NES.Console{}, positive_instruction_count}, got: #{inspect(other)}"
    end
  end

  @doc "Compare a candidate repeatedly, carrying each side's resulting state."
  def compare_many(%Console{} = console, candidate, transitions)
      when is_function(candidate, 1) and is_integer(transitions) and transitions >= 0 do
    do_compare_many(console, console, candidate, transitions, 0)
  end

  @doc "Raise with a deterministic mismatch report unless one transition is equivalent."
  def assert_equivalent!(%Console{} = console, candidate) when is_function(candidate, 1) do
    case compare(console, candidate) do
      {:ok, actual} ->
        actual

      {:error, mismatch} ->
        raise "CPU execution mismatch: #{inspect(mismatch, base: :hex, limit: :infinity)}"
    end
  end

  @doc "The exact state currently covered by the AOT equivalence contract."
  def snapshot(%Console{cpu: %CPU{} = cpu, bus: bus}) do
    %{
      cpu: Map.take(cpu, @cpu_fields),
      ram: bus.ram,
      wram: bus.wram,
      mapper: bus.mapper,
      prg_banks: bus.prg_banks,
      mapper_state: bus.mapper_state
    }
  end

  defp do_compare_many(_expected, actual, _candidate, 0, _index), do: {:ok, actual}

  defp do_compare_many(expected, actual, candidate, remaining, index) do
    case candidate.(actual) do
      {%Console{} = next_actual, count} when is_integer(count) and count > 0 ->
        next_expected = run_interpreter(expected, count)

        case difference(next_expected, next_actual) do
          nil ->
            do_compare_many(next_expected, next_actual, candidate, remaining - 1, index + 1)

          diff ->
            {:error,
             %{
               transition: index,
               instruction_count: count,
               start_pc: expected.cpu.pc,
               expected: snapshot(next_expected),
               actual: snapshot(next_actual),
               difference: diff
             }}
        end

      other ->
        raise ArgumentError,
              "candidate must return {%Beamicom.NES.Console{}, positive_instruction_count}, got: #{inspect(other)}"
    end
  end

  defp run_interpreter(console, count) do
    Enum.reduce(1..count, console, fn _, state -> Console.step(state) end)
  end

  defp difference(expected, actual) do
    expected = snapshot(expected)
    actual = snapshot(actual)

    Enum.find_value([:cpu, :ram, :wram, :mapper, :prg_banks, :mapper_state], fn field ->
      expected_value = Map.fetch!(expected, field)
      actual_value = Map.fetch!(actual, field)

      if expected_value == actual_value,
        do: nil,
        else: %{field: field, expected: expected_value, actual: actual_value}
    end)
  end
end
