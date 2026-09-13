defmodule Mix.Tasks.Nes.Bench do
  @shortdoc "Measure a deterministic, uncapped NES workload (audio and video enabled)"
  @moduledoc """
  mix nes.bench ROM [--seconds 15] [--repeats 3] [--renderer native|nx|nx_atlas] [--audio-renderer native|elixir_block|nx_block] [--rgb-consumers 0] [--output result.json] [--profile]

  Each run cold-boots with no buttons pressed. One untimed run warms code before
  measurements. Hashing is outside the per-frame timer, but included in wall time.
  --profile performs a separate tprof run; its timings are not benchmark results.
  --profile-only skips the benchmark and runs only tprof.
  """
  use Mix.Task
  @compile {:no_warn_undefined, :tprof}
  @compile {:no_warn_undefined, Beamicom.NES.Nx.PPURenderer}
  @compile {:no_warn_undefined, Beamicom.NES.Nx.PPUAtlasRenderer}
  @compile {:no_warn_undefined, Beamicom.NES.Nx.APUBlockRenderer}

  @impl true
  def run(args) do
    {opts, [path], []} =
      OptionParser.parse(args,
        strict: [
          seconds: :integer,
          repeats: :integer,
          output: :string,
          renderer: :string,
          audio_renderer: :string,
          rgb_consumers: :integer,
          profile: :boolean,
          profile_only: :boolean
        ]
      )

    Mix.Task.run("app.start")
    configured_ppu = Beamicom.NES.PPU.configured_renderer()

    renderer =
      opts
      |> Keyword.get(:renderer, configured_ppu_name(configured_ppu))
      |> String.to_existing_atom()

    if renderer not in [:native, :nx, :nx_atlas],
      do: Mix.raise("renderer must be native, nx, or nx_atlas")

    if renderer in [:nx, :nx_atlas] and not Code.ensure_loaded?(Beamicom.NES.Nx.PPURenderer),
      do: Mix.raise("the nx renderer requires running this task from the beamicom_nes_nx project")

    renderer_module =
      case renderer do
        :native -> :native
        :nx -> Beamicom.NES.Nx.PPURenderer
        :nx_atlas -> Beamicom.NES.Nx.PPUAtlasRenderer
      end

    if renderer_module != configured_ppu,
      do:
        Mix.raise(
          "PPU renderer is compile-time; this build contains #{configured_ppu_name(configured_ppu)}"
        )

    configured_apu = Beamicom.NES.Bus.configured_apu_renderer()
    audio_renderer = Keyword.get(opts, :audio_renderer, configured_apu_name(configured_apu))

    audio_renderer_module =
      case audio_renderer do
        "native" -> :native
        "elixir_block" -> Beamicom.NES.APUBlockRenderer
        "nx_block" -> Beamicom.NES.Nx.APUBlockRenderer
        _ -> Mix.raise("audio-renderer must be native, elixir_block, or nx_block")
      end

    if audio_renderer_module != :native and not Code.ensure_loaded?(audio_renderer_module),
      do:
        Mix.raise(
          "the Nx audio renderer requires running this task from the beamicom_nes_nx project"
        )

    if audio_renderer_module != configured_apu,
      do:
        Mix.raise(
          "APU renderer is compile-time; this build contains #{configured_apu_name(configured_apu)}"
        )

    media = File.read!(path)
    seconds = Keyword.get(opts, :seconds, 15)
    repeats = Keyword.get(opts, :repeats, 3)
    rgb_consumers = Keyword.get(opts, :rgb_consumers, 0)

    if seconds < 1 or repeats < 1 or rgb_consumers < 0,
      do: Mix.raise("seconds and repeats must be positive; rgb-consumers cannot be negative")

    frames = ceil(seconds * 60.0988)

    if opts[:profile_only] do
      profile(media, frames, rgb_consumers)
    else
      {:ok, cart} = Beamicom.NES.Cart.parse(media)
      execute(media, frames, rgb_consumers)
      runs = for _ <- 1..repeats, do: execute(media, frames, rgb_consumers)
      hashes = Enum.map(runs, &{&1.video_sha256, &1.audio_sha256, &1.state_sha256})
      if length(Enum.uniq(hashes)) != 1, do: Mix.raise("non-deterministic output")

      result = %{
        rom_sha256: hash(media),
        mapper: cart.mapper,
        frames: frames,
        input: "none; cold boot",
        emulated_seconds: frames / 60.0988,
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release)),
        schedulers: :erlang.system_info(:schedulers_online),
        renderer: renderer,
        audio_renderer: String.to_atom(audio_renderer),
        rgb_consumers: rgb_consumers,
        runs: runs
      }

      json = IO.iodata_to_binary(:json.encode(result))
      IO.puts(json)
      if path = opts[:output], do: File.write!(path, json <> "\n")

      if opts[:profile] do
        profile(media, frames, rgb_consumers)
      end
    end
  end

  defp profile(media, frames, rgb_consumers) do
    Mix.ensure_application!(:tools)

    :tprof.profile(
      fn -> execute(media, frames, rgb_consumers) end,
      %{type: :call_time, report: {:total, {:measurement, :descending}}}
    )
  end

  defp execute(media, frames, rgb_consumers) do
    {:ok, machine} = Beamicom.NES.System.load(media)
    :erlang.garbage_collect()
    {_, reductions0} = Process.info(self(), :reductions)
    started = System.monotonic_time(:microsecond)

    {machine, times, video, audio, samples} =
      Enum.reduce(
        1..frames,
        {machine, [], :crypto.hash_init(:sha256), :crypto.hash_init(:sha256), 0},
        fn _, {machine, times, vh, ah, count} ->
          {us, {machine, [video, audio]}} =
            :timer.tc(fn ->
              {machine, [video, audio]} = Beamicom.NES.System.run_slice(machine)
              consume_rgb(video.data, rgb_consumers)
              {machine, [video, audio]}
            end)

          vh = :crypto.hash_update(vh, Beamicom.NES.Palette.to_rgb(video.data))
          ah = :crypto.hash_update(ah, audio.data)
          {machine, [us | times], vh, ah, count + audio.frame_count}
        end
      )

    wall_us = System.monotonic_time(:microsecond) - started
    {_, reductions1} = Process.info(self(), :reductions)
    sorted = Enum.sort(times)
    total = Enum.sum(times)

    %{
      core_ms: total / 1000,
      wall_ms: wall_us / 1000,
      fps: frames * 1_000_000 / total,
      realtime_multiple: frames / 60.0988 * 1_000_000 / total,
      mean_frame_ms: total / frames / 1000,
      p50_frame_ms: Enum.at(sorted, ceil(frames * 0.50) - 1) / 1000,
      p95_frame_ms: Enum.at(sorted, ceil(frames * 0.95) - 1) / 1000,
      p99_frame_ms: Enum.at(sorted, ceil(frames * 0.99) - 1) / 1000,
      max_frame_ms: List.last(sorted) / 1000,
      over_budget_frames: Enum.count(times, &(&1 > 1_000_000 / 60.0988)),
      reductions: reductions1 - reductions0,
      cpu_cycles: machine.cpu.cycles,
      audio_samples: samples,
      video_sha256: Base.encode16(:crypto.hash_final(video), case: :lower),
      audio_sha256: Base.encode16(:crypto.hash_final(audio), case: :lower),
      state_sha256: hash_state(machine)
    }
  end

  defp hash_state(%{bus: %{apu_renderer: renderer, apu_renderer_state: state} = bus} = machine)
       when renderer != :native do
    state =
      if function_exported?(renderer, :snapshot, 1),
        do: apply(renderer, :snapshot, [state]),
        else: state

    machine = %{machine | bus: %{bus | apu_renderer_state: state}}
    hash(:erlang.term_to_binary(machine, [:deterministic]))
  end

  defp hash_state(machine), do: hash(:erlang.term_to_binary(machine, [:deterministic]))

  defp configured_ppu_name(renderer),
    do:
      Map.fetch!(
        %{
          :native => "native",
          Beamicom.NES.Nx.PPURenderer => "nx",
          Beamicom.NES.Nx.PPUAtlasRenderer => "nx_atlas"
        },
        renderer
      )

  defp configured_apu_name(renderer),
    do:
      Map.fetch!(
        %{
          :native => "native",
          Beamicom.NES.APUBlockRenderer => "elixir_block",
          Beamicom.NES.Nx.APUBlockRenderer => "nx_block"
        },
        renderer
      )

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp consume_rgb(_frame, 0), do: :ok

  defp consume_rgb(frame, count) do
    Enum.each(1..count, fn _ -> Beamicom.NES.Palette.to_rgb(frame) end)
  end
end
