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

    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(BeamicomPhx.AV.Pipeline, egress_signaling: signaling)

    ref = Process.monitor(pipeline)
    # No browser peer connects here, so the pipeline never advances to :playing;
    # the point is that it does not CRASH — i.e. every element's stream format is
    # accepted end to end (RGB->I420->H264->Sink, s16le->48k->Opus->Sink).
    refute_receive {:DOWN, ^ref, :process, ^pipeline, _}, 1_500

    Membrane.Pipeline.terminate(pipeline)
  end
end
