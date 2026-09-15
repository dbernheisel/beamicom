defmodule Beamicom.NES.Recompiler.Runtime do
  @moduledoc false

  alias Beamicom.NES.{Console, CPU}

  @doc false
  def run_block(a, x, y, sp, p, cycles, ram, {%CPU{} = cpu, bus}, addresses)
      when is_binary(ram) and is_list(addresses) do
    cpu = %{cpu | a: a, x: x, y: y, sp: sp, p: p, cycles: cycles}
    console = %Console{cpu: cpu, bus: %{bus | ram: ram}}
    run_addresses(console, addresses, 0)
  end

  @doc false
  def fallback(%Console{} = console), do: {Console.step(console), 1}

  # An interrupt may redirect PC after any instruction. Stop immediately rather
  # than executing the remainder of the statically discovered straight-line
  # block; the next dispatch will select the interrupt target or fall back.
  defp run_addresses(console, [], count), do: {console, count}

  defp run_addresses(%Console{cpu: %{pc: pc}} = console, [pc | rest], count),
    do: run_addresses(Console.step(console), rest, count + 1)

  defp run_addresses(console, _addresses, count) when count > 0, do: {console, count}
end
