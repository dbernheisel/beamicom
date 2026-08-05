defmodule BeamicomPhx.AV.RtpBroadcastTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "builds and stays up sending to a local target" do
    {:ok, _sup, pid} =
      Membrane.Pipeline.start_link(BeamicomPhx.AV.RtpBroadcast, target: {{127, 0, 0, 1}, 5000})

    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_500
    Membrane.Pipeline.terminate(pid)
  end
end
