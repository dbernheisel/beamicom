defmodule Mix.Tasks.Nes.AotFrameBench do
  @shortdoc "Benchmark profiled MMC5 AOT with the configured frame renderers"
  @moduledoc """
  Usage:

      BEAMICOM_NX=1 BEAMICOM_AUDIO_48=1 mix nes.aot_frame_bench ROM \
        [--frames 60] [--profile-instructions 250000] [--output result.json]

  Runs the same cold-boot frames through the interpreter and the profiled AOT
  dispatcher, drains the configured PPU/APU outputs at identical frame
  boundaries, and rejects different audio/video hashes.
  """

  use Mix.Task

  alias Beamicom.NES.{Bus, Cart, Console, Palette, PPU}
  alias Beamicom.NES.System, as: NESSystem
  alias Beamicom.NES.Recompiler.{Generator, MMC5Profile, Program, Semantics}

  @impl true
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args,
        strict: [frames: :integer, profile_instructions: :integer, output: :string]
      )

    case {paths, invalid} do
      {[path], []} -> benchmark(path, options)
      _ -> Mix.raise("expected ROM [--frames N] [--profile-instructions N] [--output PATH]")
    end
  end

  defp benchmark(path, options) do
    Mix.Task.run("app.start")
    media = File.read!(path)
    {:ok, %Cart{mapper: 5} = cart} = Cart.parse(media)
    frames = Keyword.get(options, :frames, 60)
    profile_instructions = Keyword.get(options, :profile_instructions, 250_000)

    if frames < 1 or profile_instructions < 1,
      do: Mix.raise("frames and profile-instructions must be positive")

    profile_start = Console.load_binary(media)

    {profile_us, {:ok, profile, _profiled_console}} =
      :timer.tc(fn -> MMC5Profile.capture(profile_start, profile_instructions) end)

    {compile_us, {:ok, program}} = :timer.tc(fn -> Generator.compile(cart, profile) end)

    # Both paths get one untimed output call so EXLA execution/cache warm-up is
    # excluded symmetrically from the comparison.
    _warm_interpreter = execute(:interpreter, Console.load_binary(media), nil, 1)
    _warm_aot = execute(:aot, Console.load_binary(media), program, 1)

    stats_before = Program.statistics(program)
    _coverage = execute(:aot, Console.load_binary(media), program, frames)
    stats_after = Program.statistics(program)

    interpreter = execute(:interpreter, Console.load_binary(media), nil, frames)

    aot =
      execute(:aot, Console.load_binary(media), Program.without_statistics(program), frames)

    unless {aot.video_sha256, aot.audio_sha256} ==
             {interpreter.video_sha256, interpreter.audio_sha256},
           do: Mix.raise("AOT and interpreter frame outputs differ")

    compiled = stats_after.compiled_instructions - stats_before.compiled_instructions
    fallback = stats_after.fallback_instructions - stats_before.fallback_instructions

    result = %{
      rom: Path.basename(path),
      mapper: cart.mapper,
      frames: frames,
      profile: %{
        instructions: profile_instructions,
        wall_us: profile_us,
        signatures: MapSet.size(profile.signatures),
        mapping_changes: profile.mapping_changes,
        hot_instruction_identities: map_size(profile.hits)
      },
      compile_wall_us: compile_us,
      generated: %{
        blocks: map_size(program.discovery.blocks),
        instructions: map_size(program.discovery.instructions),
        executed_compiled_instructions: compiled,
        fallback_instructions: fallback,
        fallback_percent: percent(fallback, compiled + fallback),
        direct_lowering: Semantics.coverage(program.discovery)
      },
      interpreter: interpreter,
      aot: aot,
      measured_end_to_end_speedup: interpreter.wall_us / max(aot.wall_us, 1),
      ppu_renderer: inspect(Beamicom.NES.PPU.configured_renderer()),
      apu_renderer: inspect(Bus.configured_apu_renderer()),
      audio_sample_rate: Bus.configured_audio_sample_rate(),
      audio_host_to_device_bytes_per_frame: audio_h2d_bytes(),
      audio_device_to_host_bytes_per_frame:
        if(Bus.configured_audio_sample_rate() == 48_000, do: 1600, else: :variable),
      video_host_to_device_bytes_per_frame: 53_746,
      video_device_to_host_bytes_per_frame: 245_760,
      combined_host_to_device_bytes_per_frame: audio_h2d_bytes() + 53_746,
      output_hashes_equal: true
    }

    json = IO.iodata_to_binary(:json.encode(result))
    IO.puts(json)
    if output = options[:output], do: File.write!(output, json <> "\n")
  end

  defp execute(mode, console, program, frames) do
    started = System.monotonic_time(:microsecond)

    {console, times, video_hash, audio_hash, samples} =
      Enum.reduce(
        1..frames,
        {console, [], :crypto.hash_init(:sha256), :crypto.hash_init(:sha256), 0},
        fn _, {console, times, vh, ah, samples} ->
          {elapsed, {console, frame, sample_count, pcm}} =
            :timer.tc(fn -> run_frame(mode, console, program) end)

          vh = :crypto.hash_update(vh, Palette.to_rgb(frame))
          ah = :crypto.hash_update(ah, pcm)
          {console, [elapsed | times], vh, ah, samples + sample_count}
        end
      )

    wall_us = System.monotonic_time(:microsecond) - started
    sorted = Enum.sort(times)

    %{
      wall_us: wall_us,
      fps: frames * 1_000_000 / max(wall_us, 1),
      mean_frame_ms: Enum.sum(times) / frames / 1000,
      p50_frame_ms: percentile(sorted, 0.50) / 1000,
      p95_frame_ms: percentile(sorted, 0.95) / 1000,
      audio_samples: samples,
      dmc_active: console.bus.apu.dmc != nil,
      mmc5_audio_active: console.bus.apu.m5_active,
      video_sha256: Base.encode16(:crypto.hash_final(video_hash), case: :lower),
      audio_sha256: Base.encode16(:crypto.hash_final(audio_hash), case: :lower)
    }
  end

  defp run_frame(:interpreter, console, _program) do
    {console, [video, audio]} = NESSystem.run_slice(console)
    {console, video.data, audio.frame_count, audio.data}
  end

  defp run_frame(:aot, console, program) do
    after_number =
      case console.bus.ppu.frame_ready do
        nil -> -1
        frame -> frame.number
      end

    {console, frame} = next_frame(console, program, after_number, 1_000_000)
    audio = Task.async(fn -> Bus.take_audio_pcm(console.bus) end)
    frame = PPU.resolve_frame(frame)
    {sample_count, pcm, bus} = Task.await(audio, :infinity)
    bus = put_in(bus.ppu.frame_ready, frame)
    {%{console | bus: bus}, frame, sample_count, pcm}
  end

  defp next_frame(_console, _program, _after_number, 0),
    do: Mix.raise("AOT did not produce a frame")

  defp next_frame(console, program, after_number, remaining) do
    {console, count} = Program.step(program, console)

    case console.bus.ppu.frame_ready do
      %{number: number} = frame when number > after_number -> {console, frame}
      _ -> next_frame(console, program, after_number, remaining - count)
    end
  end

  defp audio_h2d_bytes do
    if Bus.configured_audio_sample_rate() == 48_000,
      do: 128 * 3 * 4 + 4 + 4 + 4096 * 4 + 4096 * 8,
      else: 0
  end

  defp percentile(sorted, fraction), do: Enum.at(sorted, ceil(length(sorted) * fraction) - 1)
  defp percent(_part, 0), do: 0.0
  defp percent(part, total), do: part * 100.0 / total
end
