defmodule BeamicomPhx.AV.RelayTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "starts and listens without a stream present" do
    # The test wrapper starts an anonymous pipeline, avoiding the production
    # registration while giving ExUnit ownership of the Membrane supervisor.
    start_supervised!(
      {BeamicomPhx.TestPipeline, {BeamicomPhx.AV.Relay, [listen_port: 5100], self()}}
    )

    assert_receive {:test_pipeline_started, pid}
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  test "attaching a browser before the stream arrives succeeds without crashing" do
    start_supervised!(
      {BeamicomPhx.TestPipeline, {BeamicomPhx.AV.Relay, [listen_port: 5102], self()}}
    )

    assert_receive {:test_pipeline_started, pid}
    ref = Process.monitor(pid)

    # Tees exist from init (no SessionBin wait), so attach returns :ok immediately
    # and must NOT crash the shared relay.
    reply =
      Membrane.Pipeline.call(pid, {:add_browser, "b1", self(), Membrane.WebRTC.Signaling.new()})

    assert reply == :ok
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 800
  end
end
