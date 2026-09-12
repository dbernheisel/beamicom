defmodule Mix.Tasks.Nes.Bench do
  @shortdoc "Measure a deterministic, uncapped NES workload (audio and video enabled)"
  @moduledoc """
  mix nes.bench ROM [--seconds 15] [--repeats 3] [--output result.json] [--profile]

  Each run cold-boots with no buttons pressed. One untimed run warms code before
  measurements. Hashing is outside the per-frame timer, but included in wall time.
  --profile performs a separate tprof run; its timings are not benchmark results.
  --profile-only skips the benchmark and runs only tprof.
  """
  use Mix.Task
  @compile {:no_warn_undefined, :tprof}

  @impl true
  def run(args) do
    {opts, [path], []} =
      OptionParser.parse(args,
        strict: [
          seconds: :integer,
          repeats: :integer,
          output: :string,
          profile: :boolean,
          profile_only: :boolean
        ]
      )

    Mix.Task.run("app.start")
    media = File.read!(path)
    seconds = Keyword.get(opts, :seconds, 15)
    repeats = Keyword.get(opts, :repeats, 3)
    if seconds < 1 or repeats < 1, do: Mix.raise("seconds and repeats must be positive")
    frames = ceil(seconds * 60.0988)

    if opts[:profile_only] do
      profile(media, frames)
    else
      {:ok, cart} = Beamicom.NES.Cart.parse(media)
      execute(media, frames)
      runs = for _ <- 1..repeats, do: execute(media, frames)
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
        runs: runs
      }

      json = IO.iodata_to_binary(:json.encode(result))
      IO.puts(json)
      if path = opts[:output], do: File.write!(path, json <> "\n")

      if opts[:profile] do
        profile(media, frames)
      end
    end
  end

  defp profile(media, frames) do
    Mix.ensure_application!(:tools)

    :tprof.profile(
      fn -> execute(media, frames) end,
      %{type: :call_time, report: {:total, {:measurement, :descending}}}
    )
  end

  defp execute(media, frames) do
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
            :timer.tc(fn -> Beamicom.NES.System.run_slice(machine) end)

          vh = :crypto.hash_update(vh, :erlang.term_to_binary(video.data, [:deterministic]))
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
      state_sha256: hash(:erlang.term_to_binary(machine, [:deterministic]))
    }
  end

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
