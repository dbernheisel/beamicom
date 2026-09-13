defmodule Beamicom.NES.APUBlockRenderer do
  @moduledoc """
  Dependency-free implementation of the deferred APU renderer contract.

  Register access and IRQ control remain on the live APU. This renderer replays
  the compact frame timeline into a private waveform state and emits PCM once at
  the output boundary.
  """

  @behaviour Beamicom.NES.APURenderer
  alias Beamicom.NES.APU

  @impl true
  def prepare(apu), do: APU.set_output(apu, true)

  @impl true
  def render(state, events, cycles, sample_inputs) do
    {dmc_samples, expansion_samples} = split_inputs(sample_inputs)
    state = APU.set_external_dmc_samples(state, dmc_samples)
    state = APU.set_external_expansion_samples(state, expansion_samples)

    {state, position} =
      Enum.reduce(events, {state, 0}, fn {at, addr, value}, {state, position} ->
        state = advance(state, at - position)

        state =
          cond do
            addr == 0x4015 and value == -1 -> elem(APU.read_status(state), 1)
            addr >= 0x5000 -> APU.mmc5_write(state, addr, value)
            true -> APU.write(state, addr, value)
          end

        {state, at}
      end)

    state = advance(state, cycles - position)
    {count, pcm, state} = APU.take_pcm(state)

    unless APU.external_dmc_consumed?(state),
      do: raise("Elixir APU block did not consume the complete DMC level stream")

    unless APU.external_expansion_consumed?(state),
      do: raise("Elixir APU block did not consume the complete expansion level stream")

    {count, pcm, state |> APU.clear_external_samples() |> Map.put(:dmc, nil)}
  end

  @impl true
  def supports_event?(addr, _value),
    do: addr in 0x4000..0x4013 or addr in [0x4015, 0x4017] or addr in 0x5000..0x5015

  @impl true
  def snapshot(state), do: state

  @impl true
  def restore(state), do: state

  defp advance(state, 0), do: state
  defp advance(state, cycles), do: state |> APU.tick(cycles) |> APU.flush()

  defp split_inputs(inputs) do
    inputs
    |> Enum.map(fn
      {dmc, expansion} -> {dmc, expansion}
      dmc when is_integer(dmc) -> {dmc, 0.0}
    end)
    |> Enum.unzip()
  end
end
