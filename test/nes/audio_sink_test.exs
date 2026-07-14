defmodule Beamicom.NES.AudioSinkTest do
  # Shares the application-started Output.
  use ExUnit.Case, async: false

  alias Beamicom.NES.AudioSink

  test "encodes samples to signed little-endian 16-bit PCM" do
    assert AudioSink.pcm([0, 1, -1, 258]) == <<0, 0, 1, 0, 255, 255, 2, 1>>
  end

  test "streams audio chunks to its port without crashing" do
    # Pipe to `cat` instead of ffplay so the test needs no audio device.
    pid = start_supervised!({AudioSink, command: ["cat"], name: :test_audio_sink})

    send(pid, {:audio, [100, -100, 200]})
    send(pid, {:frame, 0})
    # Force the mailbox to drain (FIFO), then confirm the sink is still alive.
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
