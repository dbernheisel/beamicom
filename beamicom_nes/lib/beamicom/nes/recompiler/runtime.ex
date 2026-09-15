defmodule Beamicom.NES.Recompiler.Runtime do
  @moduledoc false

  alias Beamicom.NES.{CPU, Console}

  @doc false
  def run_block(a, x, y, sp, p, cycles, ram, {%CPU{} = cpu, bus}, addresses)
      when is_binary(ram) and is_list(addresses) do
    cpu = %{cpu | a: a, x: x, y: y, sp: sp, p: p, cycles: cycles}
    bus = %{bus | ram: ram}
    {cpu, bus, count} = run_instructions(cpu, bus, addresses, 0)
    {%Console{cpu: cpu, bus: bus}, count}
  end

  @doc false
  def fallback(%Console{} = console), do: {Console.step(console), 1}

  # An interrupt may redirect PC after any instruction. Stop immediately rather
  # than executing the remainder of the statically discovered straight-line
  # block; the next dispatch will select the interrupt target or fall back.
  defp run_instructions(cpu, bus, [], count), do: {cpu, bus, count}

  defp run_instructions(
         %CPU{pc: pc} = cpu,
         bus,
         [{pc, operation, mode, base_cycles} | rest],
         count
       ) do
    {cpu, bus} = CPU.step_known(cpu, bus, operation, mode, base_cycles)
    run_instructions(cpu, bus, rest, count + 1)
  end

  defp run_instructions(cpu, bus, _instructions, count) when count > 0,
    do: {cpu, bus, count}
end
