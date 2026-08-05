defmodule BeamicomPhx.AV.RelayTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "starts and listens without a stream present" do
    # Use Membrane.Pipeline.start_link/2 directly (not the named start_link/1 in
    # BeamicomPhx.AV.Relay) so we get an anonymous pipeline that won't clash with
    # a running app instance.
    {:ok, _sup, pid} = Membrane.Pipeline.start_link(BeamicomPhx.AV.Relay, listen_port: 5100)
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    Membrane.Pipeline.terminate(pid)
  end

  test "attaching a browser before the stream arrives succeeds without crashing" do
    {:ok, _sup, pid} = Membrane.Pipeline.start_link(BeamicomPhx.AV.Relay, listen_port: 5102)
    ref = Process.monitor(pid)

    # Tees exist from init (no SessionBin wait), so attach returns :ok immediately
    # and must NOT crash the shared relay.
    reply =
      Membrane.Pipeline.call(pid, {:add_browser, "b1", self(), Membrane.WebRTC.Signaling.new()})

    assert reply == :ok
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 800
    Membrane.Pipeline.terminate(pid)
  end
end
