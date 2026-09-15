defmodule Mix.Tasks.Nes.BenchFrameVideo do
  @shortdoc "Benchmark the fixed-shape mapper-0 EXLA frame-video call"
  @moduledoc """
  Usage:

      BEAMICOM_NX=1 mix nes.bench_frame_video [--frames 300]

  The immutable CHR atlas is copied to the EXLA host client once. Reported
  host-to-device bytes count only changing per-frame inputs.
  """

  use Mix.Task

  alias Beamicom.NES.Nx.FrameVideoExecutable

  @impl true
  def run(arguments) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: [frames: :integer])

    if positional != [] or invalid != [], do: Mix.raise("expected only [--frames N]")
    frames = Keyword.get(options, :frames, 300)
    if frames < 1, do: Mix.raise("frames must be positive")
    Mix.Task.run("app.start")

    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-bench-#{System.unique_integer([:positive])}.cache"
      )

    try do
      {:ok, compiled, _source} = FrameVideoExecutable.load(path)
      args = arguments()
      _warm = invoke(compiled, args)

      times =
        for _ <- 1..frames do
          {microseconds, _result} = :timer.tc(fn -> invoke(compiled, args) end)
          microseconds
        end

      sorted = Enum.sort(times)

      result = %{
        frames: frames,
        mean_frame_us: Enum.sum(times) / frames,
        p50_frame_us: percentile(sorted, 0.50),
        p95_frame_us: percentile(sorted, 0.95),
        p99_frame_us: percentile(sorted, 0.99),
        host_to_device_bytes_per_frame: 2048 + 256 + 256 * 3 * 4 + 4 + 7 * 4,
        resident_chr_atlas_bytes: 512 * 8 * 8,
        device_to_host_frame_bytes: 240 * 256,
        client: "EXLA host",
        note: "video-only mapper-0 raw-state kernel"
      }

      IO.puts(:json.encode(result))
    after
      File.rm(path)
    end
  end

  defp arguments do
    backend = Beamicom.NES.Nx.backend()

    [
      Nx.broadcast(Nx.tensor(0, type: :u8), {2048}),
      Nx.from_binary(:binary.copy(<<0xFF, 0, 0, 0>>, 64), :u8),
      Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8}) |> Nx.backend_copy(backend),
      Nx.broadcast(Nx.tensor(0, type: :s32), {256, 3}),
      Nx.tensor(0, type: :s32),
      Nx.tensor([0, 0, 0, 0, 0, 1, 0], type: :s32)
    ]
  end

  defp invoke(compiled, args) do
    {frame, overflow, hit} = apply(compiled, args)
    {Nx.to_binary(frame), Nx.to_number(overflow), Nx.to_number(hit)}
  end

  defp percentile(sorted, fraction),
    do: Enum.at(sorted, ceil(length(sorted) * fraction) - 1)
end
