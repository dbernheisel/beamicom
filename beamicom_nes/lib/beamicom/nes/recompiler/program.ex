defmodule Beamicom.NES.Recompiler.Program do
  @moduledoc """
  Loaded generated-ROM module plus per-instance execution counters.

  Counters are observational only and do not participate in emulation state.
  """

  alias Beamicom.NES.Console

  @enforce_keys [:module, :rom_hash, :discovery, :stats]
  defstruct [:module, :rom_hash, :discovery, :stats]

  @doc "Dispatch one generated block or one interpreter fallback instruction."
  def step(%__MODULE__{} = program, %Console{} = console) do
    known? = program.module.known_block?(console.cpu.pc)
    {next, count} = program.module.dispatch(console)

    if known? do
      :atomics.add(program.stats, 1, 1)
      :atomics.add(program.stats, 2, count)
    else
      :atomics.add(program.stats, 3, 1)
      :atomics.add(program.stats, 4, count)
    end

    {next, count}
  end

  @doc "Return generated/fallback transition and instruction totals."
  def statistics(%__MODULE__{stats: stats}) do
    %{
      compiled_blocks: :atomics.get(stats, 1),
      compiled_instructions: :atomics.get(stats, 2),
      fallback_transitions: :atomics.get(stats, 3),
      fallback_instructions: :atomics.get(stats, 4)
    }
  end
end
