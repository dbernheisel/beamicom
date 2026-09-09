defmodule BeamicomPhx.AV.RtpBroadcastTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "builds and stays up sending to a local target" do
    start_supervised!(
      {BeamicomPhx.TestPipeline,
       {BeamicomStream.AV.RtpBroadcast, [target: {{127, 0, 0, 1}, 5000}], self()}}
    )

    assert_receive {:test_pipeline_started, pid}
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_500
  end
end
