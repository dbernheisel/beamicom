defmodule Beamicom.NES.Nx.APUBlockRendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.APU
  alias Beamicom.NES.Nx.APUBlockRenderer

  setup do
    previous = Application.get_env(:beamicom_nes, :apu_renderer, :native)
    on_exit(fn -> Application.put_env(:beamicom_nes, :apu_renderer, previous) end)
    :ok
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

  test "live frame event capture is exact and survives save-state restore" do
    media = File.read!("../beamicom_nes/test/support/fixtures/nestest.nes")

    Application.put_env(:beamicom_nes, :apu_renderer, :native)
    {:ok, native} = Beamicom.NES.System.load(media)
    {native, native_pcm} = run_frames(native, 4, [])

    Application.put_env(:beamicom_nes, :apu_renderer, Beamicom.NES.APUBlockRenderer)
    {:ok, elixir_block} = Beamicom.NES.System.load(media)
    {_elixir_block, elixir_pcm} = run_frames(elixir_block, 4, [])
    assert elixir_pcm == native_pcm

    Application.put_env(:beamicom_nes, :apu_renderer, APUBlockRenderer)
    {:ok, accelerated} = Beamicom.NES.System.load(media)
    {accelerated, first_pcm} = run_frames(accelerated, 2, [])
    {state, rom} = Beamicom.NES.SaveState.split(accelerated)
    assert {:ok, restored} = Beamicom.NES.SaveState.merge(state, rom)
    {restored, rest_pcm} = run_frames(restored, 2, [])
    nx_pcm = first_pcm <> rest_pcm

    assert nx_pcm == native_pcm
    assert restored.cpu == native.cpu
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
end
