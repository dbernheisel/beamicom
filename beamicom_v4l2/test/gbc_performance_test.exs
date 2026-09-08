defmodule BeamicomV4L2.GBCPerformanceTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{AudioChunk, Output}
  alias BeamicomV4L2.Runtime

  @moduletag :performance
  @warmup_frames 30
  @frames 300
  @sample_rate 44_100

  test "paced CGB steady-state workload produces continuous real-time audio" do
    path = System.fetch_env!("BEAMICOM_GBC_PERF_ROM")
    assert File.regular?(path), "performance ROM is unavailable at #{path}"
    assert {:ok, machine} = path |> File.read!() |> GBSystem.load()

    output = start_supervised!({Output, []})
    :ok = Output.subscribe_audio(output)

    runtime =
      start_supervised!({Runtime, machine: machine, output: output, pace: true})

    _discarded_startup_samples = receive_samples(@warmup_frames, :warmup)
    started_at = System.monotonic_time(:microsecond)
    sample_count = receive_samples(@frames, :measurement)

    elapsed_us = System.monotonic_time(:microsecond) - started_at
    audio_us = sample_count * 1_000_000 / @sample_rate
    coverage = audio_us / elapsed_us
    {:message_queue_len, queue_length} = Process.info(runtime, :message_queue_len)

    IO.puts(
      "GBC paced objective: #{Float.round(elapsed_us / 1_000, 1)} ms wall, " <>
        "#{Float.round(audio_us / 1_000, 1)} ms PCM, " <>
        "#{Float.round(coverage * 100, 1)}% coverage"
    )

    assert coverage >= 0.98
    assert queue_length <= 1
  end

  defp receive_samples(frames, phase) do
    Enum.reduce(1..frames, 0, fn frame, total ->
      assert_receive {:audio_chunk, %AudioChunk{frame_count: count}},
                     2_000,
                     "audio timed out during #{phase} at frame #{frame}"

      total + count
    end)
  end
end
