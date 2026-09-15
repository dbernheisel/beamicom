defmodule Beamicom.NES.Nx.FrameAPURendererTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.NES.APU
  alias Beamicom.NES.Nx.FrameAPURenderer

  test "CPU-timed DMC and MMC5 levels feed one donated 48 kHz frame" do
    cycles = 29_781
    sample = :binary.copy(<<0xA5>>, 17)

    events = [
      {0, 0x4010, 0x4F},
      {0, 0x4011, 48},
      {0, 0x4000, 0xBF},
      {0, 0x4002, 0xFD},
      {0, 0x4003, 0x08},
      {0, 0x5000, 0xBF},
      {0, 0x5002, 0xA0},
      {0, 0x5003, 0x08},
      {0, 0x5015, 0x01},
      {0, 0x4015, 0x11}
    ]

    control =
      APU.new()
      |> APU.set_output(false)
      |> APU.set_renderer_sample_rate(FrameAPURenderer.sample_input_rate())
      |> apply_events(events, sample)
      |> APU.tick(cycles)
      |> APU.flush()

    {sample_inputs, _control} = APU.take_renderer_samples(control)
    assert length(sample_inputs) in 3194..3195
    assert Enum.any?(sample_inputs, fn {dmc, _m5} -> dmc != 0 end)

    state = FrameAPURenderer.prepare(APU.new())
    assert donatable_tree?(state)

    assert {800, pcm, next_state} =
             FrameAPURenderer.render(state, events, cycles, sample_inputs)

    assert byte_size(pcm) == 1600
    assert pcm != :binary.copy(<<0>>, 1600)
    assert donatable_tree?(next_state)
  end

  test "advertises the opt-in host and synthesis rates" do
    assert FrameAPURenderer.sample_rate() == 48_000
    assert FrameAPURenderer.sample_input_rate() == 192_000
  end

  defp apply_events(apu, events, sample) do
    Enum.reduce(events, apu, fn {_cycle, addr, value}, apu ->
      apu =
        cond do
          addr >= 0x5000 -> APU.mmc5_write(apu, addr, value)
          true -> APU.write(apu, addr, value)
        end

      if addr == 0x4015 and (value &&& 0x10) != 0,
        do: APU.dmc_start(apu, sample),
        else: apu
    end)
  end

  defp donatable_tree?(%Nx.Tensor{} = tensor), do: Nx.donatable?(tensor)

  defp donatable_tree?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&donatable_tree?/1)

  defp donatable_tree?(map) when is_map(map),
    do: map |> Map.values() |> Enum.all?(&donatable_tree?/1)
end
