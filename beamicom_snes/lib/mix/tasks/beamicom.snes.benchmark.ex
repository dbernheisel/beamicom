defmodule Mix.Tasks.Beamicom.Snes.Benchmark do
  use Mix.Task

  alias Beamicom.SNES.Machine

  @shortdoc "Benchmarks the native SNES core with a local ROM"
  @default_roms ["roms/Final Fantasy III.sfc", "roms/Final Fantasy 3.sfc"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [warmup: :integer, frames: :integer, minimum_fps: :float]
      )

    if invalid != [], do: Mix.raise("invalid benchmark options: #{inspect(invalid)}")

    path = List.first(paths) || default_rom!()
    warmup = positive_option!(opts, :warmup, 180)
    frames = positive_option!(opts, :frames, 360)
    minimum_fps = Keyword.get(opts, :minimum_fps, 60.0)

    {:ok, machine} = path |> File.read!() |> Machine.load()
    {machine, warmup_frame} = run_frames!(machine, warmup)

    if all_black?(warmup_frame) do
      Mix.raise("#{Path.basename(path)} still produced an all-black frame after #{warmup} frames")
    end

    renders_before = machine.bus.ppu.rendered_frames
    reuses_before = machine.bus.ppu.reused_frames
    started = System.monotonic_time()
    {machine, frame} = run_frames!(machine, frames)
    elapsed = System.monotonic_time() - started
    elapsed_seconds = System.convert_time_unit(elapsed, :native, :microsecond) / 1_000_000
    fps = frames / elapsed_seconds

    Mix.shell().info("ROM: #{path}")
    Mix.shell().info("Frames: #{frames} after #{warmup} warmup frames")
    Mix.shell().info(:io_lib.format("Throughput: ~.2f FPS (~.2f ms/frame)", [fps, 1_000 / fps]))

    Mix.shell().info(
      "PPU: #{machine.bus.ppu.rendered_frames - renders_before} rendered, " <>
        "#{machine.bus.ppu.reused_frames - reuses_before} reused; " <>
        "last RGB CRC32=#{:erlang.crc32(frame.data)}"
    )

    if fps < minimum_fps do
      Mix.raise(
        :io_lib.format("native throughput ~.2f FPS is below the ~.2f FPS requirement", [
          fps,
          minimum_fps
        ])
        |> IO.iodata_to_binary()
      )
    end
  end

  defp run_frames!(machine, count), do: run_frames!(machine, count, nil)
  defp run_frames!(machine, 0, frame), do: {machine, frame}

  defp run_frames!(machine, remaining, _frame) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, frame} ->
        {_audio_frames, _pcm, machine} = Machine.take_audio_pcm(machine)
        run_frames!(machine, remaining - 1, frame)

      {:error, reason, _machine} ->
        Mix.raise("emulation stopped: #{inspect(reason)}")
    end
  end

  defp all_black?(%{data: data}), do: data == :binary.copy(<<0>>, byte_size(data))

  defp positive_option!(opts, key, default) do
    value = Keyword.get(opts, key, default)
    if is_integer(value) and value > 0, do: value, else: Mix.raise("--#{key} must be positive")
  end

  defp default_rom! do
    Enum.find(@default_roms, &File.regular?/1) ||
      Mix.raise("pass the path to an SNES ROM; no Final Fantasy III ROM was found in roms/")
  end
end
