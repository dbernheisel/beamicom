defmodule BeamicomStream.AV.RtpBroadcastTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "starts the native AV1/Opus pipeline" do
    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(BeamicomStream.AV.RtpBroadcast,
        target: {{127, 0, 0, 1}, 15_000}
      )

    ref = Process.monitor(pipeline)
    refute_receive {:DOWN, ^ref, :process, ^pipeline, _reason}, 1_500
    Membrane.Pipeline.terminate(pipeline)
  end
end
