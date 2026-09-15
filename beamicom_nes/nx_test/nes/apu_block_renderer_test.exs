defmodule Beamicom.NES.Nx.APUBlockRendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.APU
  alias Beamicom.NES.Nx.APUBlockRenderer

  test "persistent oscillator state is fixed-point and donated on every compiled frame call" do
    state = APUBlockRenderer.prepare(APU.new())
    assert state |> Map.values() |> List.flatten() |> Enum.all?(&donatable_tree?/1)
    assert fixed_tree?(state)

    {_count, _pcm, next_state} = APUBlockRenderer.render(state, [], 100, [])
    assert next_state |> Map.values() |> List.flatten() |> Enum.all?(&donatable_tree?/1)
    assert fixed_tree?(next_state)
  end

  test "block rendering mixes a native-timed DMC stream exactly" do
    sample = :binary.copy(<<0xA5>>, 17)

    events = [
      {0, 0x4010, 0x0F},
      {0, 0x4011, 48},
      {0, 0x4000, 0xBF},
      {0, 0x4002, 0xFD},
      {0, 0x4003, 0x08},
      {0, 0x4015, 0x11}
    ]

    initial = APU.new()
    reference = apply_events(initial, events, sample) |> APU.tick(20_000)
    {expected_count, expected_pcm, _reference} = APU.take_pcm(reference)

    control =
      initial
      |> APU.set_output(false)
      |> apply_events(events, sample)
      |> APU.tick(20_000)
      |> APU.flush()

    {dmc_levels, _control} = APU.take_dmc_samples(control)

    state = APUBlockRenderer.prepare(initial)
    {count, pcm, _state} = APUBlockRenderer.render(state, events, 20_000, dmc_levels)

    assert count == expected_count
    assert pcm == expected_pcm
    assert length(dmc_levels) == expected_count
  end

  test "block rendering mixes native-timed Sunsoft 5B samples exactly" do
    cycles = 40_000

    configure = fn apu ->
      apu
      |> APU.sunsoft5b_select(0)
      |> APU.sunsoft5b_write(100)
      |> APU.sunsoft5b_select(1)
      |> APU.sunsoft5b_write(0)
      |> APU.sunsoft5b_select(7)
      |> APU.sunsoft5b_write(0x3E)
      |> APU.sunsoft5b_select(8)
      |> APU.sunsoft5b_write(15)
    end

    reference = configure.(APU.new()) |> APU.tick(cycles)
    {expected_count, expected_pcm, _reference} = APU.take_pcm(reference)

    control = configure.(APU.set_output(APU.new(), false)) |> APU.tick(cycles) |> APU.flush()
    {sample_inputs, _control} = APU.take_renderer_samples(control)

    {count, pcm, _state} =
      APUBlockRenderer.render(APUBlockRenderer.prepare(APU.new()), [], cycles, sample_inputs)

    assert count == expected_count
    assert pcm == expected_pcm
  end

  test "fixed-point filters remain sample-exact across five seconds" do
    initial =
      APU.new()
      |> APU.write(0x4015, 0x01)
      |> APU.write(0x4000, 0xBF)
      |> APU.write(0x4002, 0xFD)
      |> APU.write(0x4003, 0x08)

    Enum.reduce(1..301, {initial, APUBlockRenderer.prepare(initial)}, fn _, {reference, state} ->
      reference = APU.tick(reference, 29_780)
      {expected_count, expected_pcm, reference} = APU.take_pcm(reference)
      {count, pcm, state} = APUBlockRenderer.render(state, [], 29_780, [])

      assert count == expected_count
      assert pcm == expected_pcm
      {reference, state}
    end)
  end

  test "live frame event capture is exact and survives save-state restore" do
    media = File.read!("test/support/fixtures/nestest.nes")
    {:ok, accelerated} = Beamicom.NES.System.load(media)
    {accelerated, first_pcm} = run_frames(accelerated, 2, [])
    {state, rom} = Beamicom.NES.SaveState.split(accelerated)
    assert {:ok, restored} = Beamicom.NES.SaveState.merge(state, rom)
    {continued, expected_pcm} = run_frames(accelerated, 2, [])
    {restored, rest_pcm} = run_frames(restored, 2, [])

    assert byte_size(first_pcm) > 0
    assert rest_pcm == expected_pcm
    assert restored.cpu == continued.cpu
  end

  defp apply_events(apu, events, sample) do
    Enum.reduce(events, apu, fn {_cycle, addr, value}, apu ->
      apu = APU.write(apu, addr, value)

      if addr == 0x4015 and Bitwise.band(value, 0x10) != 0,
        do: APU.dmc_start(apu, sample),
        else: apu
    end)
  end

  defp run_frames(console, 0, pcm), do: {console, IO.iodata_to_binary(Enum.reverse(pcm))}

  defp run_frames(console, count, pcm) do
    {console, [_video, audio]} = Beamicom.NES.System.run_slice(console)
    run_frames(console, count - 1, [audio.data | pcm])
  end

  defp donatable_tree?(%Nx.Tensor{} = tensor), do: Nx.donatable?(tensor)
  defp donatable_tree?(value) when is_integer(value), do: true

  defp donatable_tree?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&donatable_tree?/1)

  defp donatable_tree?(map) when is_map(map),
    do: map |> Map.values() |> Enum.all?(&donatable_tree?/1)

  defp fixed_tree?(%Nx.Tensor{} = tensor), do: Nx.type(tensor) in [{:s, 16}, {:s, 32}, {:s, 64}]
  defp fixed_tree?(value) when is_integer(value), do: true

  defp fixed_tree?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&fixed_tree?/1)

  defp fixed_tree?(map) when is_map(map), do: map |> Map.values() |> Enum.all?(&fixed_tree?/1)
end
