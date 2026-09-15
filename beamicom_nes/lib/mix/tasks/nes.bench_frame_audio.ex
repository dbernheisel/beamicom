defmodule Mix.Tasks.Nes.BenchFrameAudio do
  @shortdoc "Benchmark the fixed 192 kHz to 48 kHz EXLA frame-audio call"

  use Mix.Task

  alias Beamicom.NES.APU
  alias Beamicom.NES.Nx.FrameAPURenderer

  @cycles 29_781
  @h2d_bytes 128 * 3 * 4 + 4 + 4 + 4096 * 4 + 4096 * 8

  @impl true
  def run(arguments) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: [frames: :integer])
    if positional != [] or invalid != [], do: Mix.raise("expected only [--frames N]")
    frames = Keyword.get(options, :frames, 100)
    if frames < 1, do: Mix.raise("frames must be positive")
    Mix.Task.run("app.start")

    {events, inputs, control} = workload()
    state = FrameAPURenderer.prepare(APU.new())
    {_count, _pcm, state} = FrameAPURenderer.render(state, events, @cycles, inputs)

    {times, {_state, _control}} =
      Enum.map_reduce(1..frames, {state, control}, fn _, {state, control} ->
        control = control |> APU.tick(@cycles) |> APU.flush()
        {inputs, control} = APU.take_renderer_samples(control)

        {elapsed, {_count, _pcm, state}} =
          :timer.tc(fn -> FrameAPURenderer.render(state, [], @cycles, inputs) end)

        {elapsed, {state, control}}
      end)

    sorted = Enum.sort(times)

    IO.puts(
      :json.encode(%{
        frames: frames,
        mean_frame_us: Enum.sum(times) / frames,
        p50_frame_us: percentile(sorted, 0.50),
        p95_frame_us: percentile(sorted, 0.95),
        p99_frame_us: percentile(sorted, 0.99),
        input_samples_192khz: length(inputs),
        output_samples_48khz: 800,
        host_to_device_bytes_per_frame: @h2d_bytes,
        device_to_host_bytes_per_frame: 1600,
        client: "EXLA host",
        channels: "2A03 + CPU-timed DMC levels + MMC5"
      })
    )
  end

  defp workload do
    events = [
      {0, 0x4010, 0x4F},
      {0, 0x4011, 48},
      {0, 0x4015, 0x10},
      {0, 0x5000, 0xBF},
      {0, 0x5002, 0xA0},
      {0, 0x5003, 0x08},
      {0, 0x5015, 0x01}
    ]

    control =
      APU.new()
      |> APU.set_output(false)
      |> APU.set_renderer_sample_rate(FrameAPURenderer.sample_input_rate())
      |> APU.write(0x4010, 0x4F)
      |> APU.write(0x4011, 48)
      |> APU.write(0x4015, 0x10)
      |> APU.dmc_start(:binary.copy(<<0xA5>>, 257))
      |> APU.mmc5_write(0x5000, 0xBF)
      |> APU.mmc5_write(0x5002, 0xA0)
      |> APU.mmc5_write(0x5003, 0x08)
      |> APU.mmc5_write(0x5015, 0x01)
      |> APU.tick(@cycles)
      |> APU.flush()

    {inputs, control} = APU.take_renderer_samples(control)
    {events, inputs, control}
  end

  defp percentile(sorted, fraction), do: Enum.at(sorted, ceil(length(sorted) * fraction) - 1)
end
