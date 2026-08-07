defmodule Beamicom.NES.AudioSinkTest do
  # Shares the application-started Output.
  use ExUnit.Case, async: false

  alias Beamicom.NES.AudioSink

  test "streams pre-encoded PCM chunks to its port without crashing" do
    # Pipe to `cat` instead of ffplay so the test needs no audio device.
    pid = start_supervised!({AudioSink, command: ["cat"], name: :test_audio_sink})

    pcm = <<100::signed-little-16, -100::signed-little-16, 200::signed-little-16>>
    send(pid, {:audio, 3, pcm})
    send(pid, {:frame, 0})
    # Force the mailbox to drain (FIFO), then confirm the sink is still alive.
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
