defmodule Mix.Tasks.Beamicom.Snes.Benchmark do
  use Mix.Task

  alias Beamicom.SNES.{DSP, Machine, SaveState, ShareImage}

  @shortdoc "Benchmarks the SNES core with a local ROM"
  @default_roms ["roms/Final Fantasy III.sfc", "roms/Final Fantasy 3.sfc"]
  @runtime_heap_words 200_000
  @profile_mfas [
    {Beamicom.SNES.CPU, :run_until_frame, 4},
    {Beamicom.SNES.CPU, :run_deferred_until_frame, 4},
    {Beamicom.SNES.CPU, :execute_deferred_until_frame, 4},
    {Beamicom.SNES.Bus, :cpu_read, 2},
    {Beamicom.SNES.Bus, :cpu_write, 3},
    {Beamicom.SNES.Bus, :cpu_idle, 2},
    {Beamicom.SNES.Bus, :flush_cpu_timing, 1},
    {Beamicom.SNES.Bus, :flush_cpu_events, 1},
    {Beamicom.SNES.Bus, :advance_master, 2},
    {Beamicom.SNES.CPU, :step_deferred, 2},
    {Beamicom.SNES.PPU, :render_frame, 1},
    {Beamicom.SNES.PPU, :nx_object_descriptors, 2},
    {Beamicom.SNES.PPU, :build_nx_object_descriptors, 3},
    {Beamicom.SNES.Nx.PPURenderer, :render, 2},
    {Beamicom.SNES.Nx.PPURenderer, :controls_tensor, 1},
    {Beamicom.SNES.Nx.PPURenderer, :object_tensor, 1},
    {Beamicom.SNES.Nx.PPURenderer, :vram_tensor, 1},
    {Beamicom.SNES.APU, :advance, 3},
    {Beamicom.SNES.APU, :advance_audio_single_pass, 4},
    {Beamicom.SNES.APU, :start_dsp_task, 6},
    {Beamicom.SNES.APU, :sync_spc_access, 5},
    {Beamicom.SNES.APU, :spc_access_requires_sync?, 5},
    {Beamicom.SNES.APU.RAM, :get, 2},
    {Beamicom.SNES.APU.RAM, :put, 3},
    {Beamicom.SNES.SPC700, :run_with_access_events, 5},
    {Beamicom.SNES.SPC700, :run_cycles, 3},
    {Beamicom.SNES.SPC700, :execute, 2},
    {Beamicom.SNES.SPC700, :read, 2},
    {Beamicom.SNES.SPC700, :write, 3},
    {Beamicom.SNES.SPC700, :sync_read_access, 3},
    {Beamicom.SNES.SPC700, :sync_write_access, 3},
    {Beamicom.SNES.SPC700, :sync_read_required?, 3},
    {Beamicom.SNES.SPC700, :sync_write_required?, 3},
    {Beamicom.SNES.SPC700, :advance_bus_cycle, 1},
    {Beamicom.SNES.SPC700, :current_cycle, 1},
    {Beamicom.SNES.SPC700, :memory_get, 2},
    {Beamicom.SNES.DSP, :ram_dependency_addresses, 3},
    {Beamicom.SNES.DSP, :clock_ram, 4},
    {Beamicom.SNES.DSP, :advance_sample, 2},
    {Beamicom.SNES.DSP.VoicePipeline, :advance_bus_before_echo, 4},
    {Beamicom.SNES.DSP.VoicePipeline, :advance_bus_to_output, 4},
    {Beamicom.SNES.DSP.VoicePipeline, :advance_voice_window, 7},
    {Beamicom.SNES.DSP.VoicePipeline, :clock_bus, 5},
    {Beamicom.SNES.DSP.Voice, :synthesize, 9},
    {Beamicom.SNES.DSP.Voice, :synthesize_tuple, 9},
    {Beamicom.SNES.DSP.Voice, :synthesize_and_advance_tuple, 11},
    {Beamicom.SNES.DSP.Voice, :advance_pitch, 4},
    {Beamicom.SNES.DSP.Voice, :contribution, 3},
    {Beamicom.SNES.DSP.Gaussian, :interpolate, 5},
    {Beamicom.SNES.DSP.Envelope, :advance, 8},
    {Beamicom.SNES.DSP.Modulation, :pitch, 4},
    {Beamicom.SNES.DSP.Mixer, :accumulate, 2},
    {Beamicom.SNES.DSP.Noise, :clock, 3},
    {Beamicom.SNES.DSP.Echo, :process_sample_transition, 6},
    {Beamicom.SNES.DSP.BRR, :decode, 3},
    {Beamicom.SNES.DSP.BRR, :decode_state, 6},
    {Beamicom.SNES.DSP.BRR, :decode_values, 8}
  ]

  @impl Mix.Task
  def run(args) do
    :erlang.process_flag(:min_heap_size, @runtime_heap_words)

    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          warmup: :integer,
          frames: :integer,
          minimum_fps: :float,
          renderer: :string,
          apu_renderer: :string,
          async_dsp: :boolean,
          profile: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid benchmark options: #{inspect(invalid)}")

    path = List.first(paths) || default_rom!()
    warmup = positive_option!(opts, :warmup, 300)
    frames = positive_option!(opts, :frames, 360)
    minimum_fps = Keyword.get(opts, :minimum_fps, 60.0)
    renderer = renderer_option!(opts)
    apu_renderer = apu_renderer_option!(opts)
    async_dsp? = Keyword.get(opts, :async_dsp, true)
    profile? = Keyword.get(opts, :profile, false)
    Application.put_env(:beamicom_snes, :ppu_renderer, renderer)

    machine = load_machine!(path, async_dsp?, apu_renderer)

    {machine, warmup_frame, _warmup_audio_frames, _warmup_pcm} = run_frames!(machine, warmup)

    if all_black?(warmup_frame) do
      Mix.raise("#{Path.basename(path)} still produced an all-black frame after #{warmup} frames")
    end

    # Do not charge the measured interval for short-lived data retained from
    # ROM loading and warm-up. Collections caused by the measured frames are
    # still included in elapsed time.
    :erlang.garbage_collect()

    renders_before = machine.bus.ppu.rendered_frames
    reuses_before = machine.bus.ppu.reused_frames
    profile_mfas = if profile?, do: start_profile(), else: []
    {machine, frame, audio_frames, pcm, measurements} = run_measured_frames!(machine, frames)
    profile = if profile?, do: finish_profile(profile_mfas), else: []
    elapsed_seconds = measurements.elapsed_microseconds / 1_000_000
    fps = frames / elapsed_seconds

    Mix.shell().info("Input: #{path}")
    Mix.shell().info("Renderer: #{renderer}")
    Mix.shell().info("APU renderer: #{inspect(apu_renderer)}")
    Mix.shell().info("APU RAM: atomics")
    Mix.shell().info("Runtime minimum heap: #{@runtime_heap_words} words")
    Mix.shell().info("Async DSP requested: #{async_dsp?}")
    Mix.shell().info("DSP scalar features active: #{dsp_scalar_required?(machine)}")
    Mix.shell().info("Frames: #{frames} after #{warmup} warmup frames")
    Mix.shell().info(:io_lib.format("Throughput: ~.2f FPS (~.2f ms/frame)", [fps, 1_000 / fps]))

    Mix.shell().info(
      :io_lib.format("Latency: p50=~.2f ms p95=~.2f ms max=~.2f ms", [
        measurements.p50_microseconds / 1_000,
        measurements.p95_microseconds / 1_000,
        measurements.max_microseconds / 1_000
      ])
    )

    Mix.shell().info(
      "PPU: #{machine.bus.ppu.rendered_frames - renders_before} rendered, " <>
        "#{machine.bus.ppu.reused_frames - reuses_before} reused; " <>
        "last RGB CRC32=#{:erlang.crc32(frame.data)}"
    )

    silent_pcm = :binary.copy(<<0>>, byte_size(pcm))
    spc_error = if machine.bus.apu.spc, do: machine.bus.apu.spc.error, else: nil

    Mix.shell().info(
      "Audio: #{audio_frames} frames in last chunk, " <>
        "signal=#{pcm != silent_pcm}, SPC error=#{inspect(spc_error)}"
    )

    Mix.shell().info(
      "Hashes: video=#{measurements.video_hash} audio=#{measurements.audio_hash} " <>
        "hardware=#{hardware_state_hash(machine)} snapshot=#{state_hash(machine)}"
    )

    if profile? do
      Mix.shell().info("Profile (instrumented call time; nested rows overlap):")

      Enum.each(profile, fn {microseconds, calls, {module, function, arity}} ->
        Mix.shell().info(
          :io_lib.format("  ~.2f ms  ~B calls  ~s.~s/~B", [
            microseconds / 1_000,
            calls,
            inspect(module),
            Atom.to_string(function),
            arity
          ])
        )
      end)
    end

    if fps < minimum_fps do
      Mix.raise(
        :io_lib.format("~s throughput ~.2f FPS is below the ~.2f FPS requirement", [
          Atom.to_string(renderer),
          fps,
          minimum_fps
        ])
        |> IO.iodata_to_binary()
      )
    end
  end

  defp run_frames!(machine, 1), do: run_frame!(machine)

  defp run_frames!(machine, remaining) when remaining > 1 do
    {machine, _frame, _audio_frames, _pcm} = run_frame!(machine)
    run_frames!(machine, remaining - 1)
  end

  defp run_measured_frames!(machine, frames) do
    video_hash = :crypto.hash_init(:sha256)
    audio_hash = :crypto.hash_init(:sha256)

    {machine, frame, audio_frames, pcm, video_hash, audio_hash, latencies} =
      Enum.reduce(
        1..frames,
        {machine, nil, 0, <<>>, video_hash, audio_hash, []},
        fn _frame_index,
           {machine, _frame, _audio_frames, _pcm, video_hash, audio_hash, latencies} ->
          started = System.monotonic_time()
          {machine, frame, audio_frames, pcm} = run_frame!(machine)
          elapsed = System.monotonic_time() - started
          elapsed = System.convert_time_unit(elapsed, :native, :microsecond)

          {
            machine,
            frame,
            audio_frames,
            pcm,
            :crypto.hash_update(video_hash, frame.data),
            :crypto.hash_update(audio_hash, pcm),
            [elapsed | latencies]
          }
        end
      )

    latencies = Enum.sort(latencies)

    measurements = %{
      elapsed_microseconds: Enum.sum(latencies),
      p50_microseconds: percentile(latencies, 50),
      p95_microseconds: percentile(latencies, 95),
      max_microseconds: List.last(latencies),
      video_hash: finish_hash(video_hash),
      audio_hash: finish_hash(audio_hash)
    }

    {machine, frame, audio_frames, pcm, measurements}
  end

  defp run_frame!(machine) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, frame} ->
        {audio_frames, pcm, machine} = Machine.take_audio_pcm(machine)
        {machine, frame, audio_frames, pcm}

      {:error, reason, _machine} ->
        Mix.raise("emulation stopped: #{inspect(reason)}")
    end
  end

  defp all_black?(%{data: data}), do: data == :binary.copy(<<0>>, byte_size(data))

  defp percentile(values, percentile) do
    index = div(length(values) * percentile + 99, 100) - 1
    Enum.at(values, max(index, 0))
  end

  defp finish_hash(context) do
    context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp state_hash(machine) do
    {state, rom} = SaveState.split(machine)

    {state, rom}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp hardware_state_hash(machine) do
    apu = %{machine.bus.apu | async_dsp?: false, apu_renderer: :native}

    ppu = %{
      machine.bus.ppu
      | render_pipeline?: false,
        rendered_frames: 0,
        reused_frames: 0
    }

    machine
    |> put_in([Access.key!(:bus), Access.key!(:apu)], apu)
    |> put_in([Access.key!(:bus), Access.key!(:ppu)], ppu)
    |> state_hash()
  end

  defp start_profile do
    mfas =
      Enum.filter(@profile_mfas, fn mfa ->
        :erlang.trace_pattern(mfa, true, [:local, :call_time]) > 0
      end)

    :erlang.trace(:all, true, [:call])
    mfas
  end

  defp finish_profile(mfas) do
    :erlang.trace(:all, false, [:call])

    profile =
      Enum.map(mfas, fn mfa ->
        entries =
          case :erlang.trace_info(mfa, :call_time) do
            {:call_time, entries} when is_list(entries) -> entries
            _other -> []
          end

        {calls, microseconds} =
          Enum.reduce(entries, {0, 0}, fn {_pid, count, seconds, microseconds},
                                          {calls, elapsed} ->
            {calls + count, elapsed + seconds * 1_000_000 + microseconds}
          end)

        {microseconds, calls, mfa}
      end)

    Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local, :call_time]))
    Enum.sort(profile, :desc)
  end

  defp positive_option!(opts, key, default) do
    value = Keyword.get(opts, key, default)
    if is_integer(value) and value > 0, do: value, else: Mix.raise("--#{key} must be positive")
  end

  defp renderer_option!(opts) do
    default = Application.get_env(:beamicom_snes, :ppu_renderer, :native)

    case Keyword.get(opts, :renderer, Atom.to_string(default)) do
      "native" -> :native
      "nx" -> :nx
      _other -> Mix.raise("--renderer must be native or nx")
    end
  end

  defp apu_renderer_option!(opts) do
    case Keyword.get(opts, :apu_renderer, "native") do
      "native" ->
        :native

      "nx" ->
        if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer),
          do: Beamicom.SNES.Nx.DSPRenderer,
          else:
            Mix.raise("Nx DSP renderer is unavailable; install the optional nx/exla dependencies")

      _other ->
        Mix.raise("--apu-renderer must be native or nx")
    end
  end

  defp default_rom! do
    Enum.find(@default_roms, &File.regular?/1) ||
      Mix.raise("pass the path to an SNES ROM; no Final Fantasy III ROM was found in roms/")
  end

  defp load_machine!(path, async_dsp?, apu_renderer) do
    media = File.read!(path)

    result =
      case media do
        <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>> ->
          ShareImage.load_image(media, [Path.dirname(path), "roms"])

        _rom ->
          Machine.load(media,
            render_pipeline: true,
            async_dsp: async_dsp?,
            apu_renderer: apu_renderer
          )
      end

    case result do
      {:ok, machine} -> configure_runtime(machine, async_dsp?, apu_renderer)
      {:error, reason} -> Mix.raise("could not load #{path}: #{inspect(reason)}")
    end
  end

  defp configure_runtime(machine, async_dsp?, apu_renderer) do
    ppu = %{machine.bus.ppu | render_pipeline?: true}
    apu = %{machine.bus.apu | async_dsp?: async_dsp?, apu_renderer: apu_renderer}
    %{machine | bus: %{machine.bus | ppu: ppu, apu: apu}}
  end

  defp dsp_scalar_required?(%{bus: %{apu: %{spc: %{dsp: dsp}}}}),
    do: DSP.scalar_required?(dsp)

  defp dsp_scalar_required?(_machine), do: false
end
