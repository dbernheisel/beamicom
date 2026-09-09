defmodule BeamicomPhx.AV.PipelineTest do
  use ExUnit.Case, async: false

  # Integration test: boots the full ex_webrtc stack (ICE/DTLS/UDP). That native
  # machinery, torn down in the same VM, disrupts a source Testing.Pipeline that
  # runs immediately after it — so this is excluded from the default `mix test`
  # run (see test_helper.exs) and run in isolation with:
  #
  #     mix test --only integration
  @moduletag :integration

  test "builds and stays up (all element formats negotiate) with a fresh signaling" do
    signaling = Membrane.WebRTC.Signaling.new()

    start_supervised!(
      {BeamicomPhx.TestPipeline, {BeamicomPhx.AV.Pipeline, [egress_signaling: signaling], self()}}
    )

    assert_receive {:test_pipeline_started, pipeline}
    ref = Process.monitor(pipeline)
    # No browser peer connects here, so the pipeline never advances to :playing;
    # the point is that it does not CRASH — i.e. every element's stream format is
    # accepted end to end (RGB->I420->H264->Sink, s16le->48k->Opus->Sink).
    refute_receive {:DOWN, ^ref, :process, ^pipeline, _}, 1_500
  end

  test "builds the 160x144 stereo Game Boy profile" do
    output = start_supervised!({Beamicom.Host.Output, name: nil})
    {:ok, core} = BeamicomStream.Core.resolve("diagnostic.gbc")
    signaling = Membrane.WebRTC.Signaling.new()

    profile = %{
      system: :gbc,
      output: output,
      video: core.capabilities.video,
      audio: core.capabilities.audio
    }

    start_supervised!(
      {BeamicomPhx.TestPipeline,
       {BeamicomPhx.AV.Pipeline,
        [
          egress_signaling: signaling,
          profile: profile
        ], self()}}
    )

    assert_receive {:test_pipeline_started, pipeline}
    ref = Process.monitor(pipeline)
    refute_receive {:DOWN, ^ref, :process, ^pipeline, _}, 1_500
  end

  test "terminates when its owning browser process exits" do
    owner = start_supervised!({Task, fn -> receive do: (:stop -> :ok) end})
    signaling = Membrane.WebRTC.Signaling.new()

    start_supervised!(
      {BeamicomPhx.TestPipeline,
       {BeamicomPhx.AV.Pipeline,
        [
          egress_signaling: signaling,
          owner: owner
        ], self()}}
    )

    assert_receive {:test_pipeline_started, pipeline}
    ref = Process.monitor(pipeline)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pipeline, _reason}, 1_500
  end
end
