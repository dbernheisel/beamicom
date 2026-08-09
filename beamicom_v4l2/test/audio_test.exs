defmodule BeamicomV4L2.AudioTest do
  use ExUnit.Case, async: false

  alias BeamicomV4L2.Audio
  import ExUnit.CaptureLog

  setup do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    :ok
  end

  test "subscribes to PCM and forwards every chunk without sound hardware" do
    audio = start_supervised!({Audio, command: ["cat"]})
    pcm = <<100::signed-little-16, -100::signed-little-16, 200::signed-little-16>>

    Beamicom.NES.Output.publish_audio(3, pcm)

    assert eventually(fn -> Audio.status(audio).samples == 3 end)
    assert %{running: true, chunks: 1, samples: 3} = Audio.status(audio)
  end

  test "reports a missing player without requiring an audio device" do
    assert {:error, {:audio_executable_not_found, "definitely-missing-audio-player"}} =
             Audio.start_link(command: ["definitely-missing-audio-player"])
  end

  test "configures ffplay's raw PCM input as mono" do
    command = Audio.default_command(1.0)

    assert ["-ch_layout", "mono"] in Enum.chunk_every(command, 2, 1, :discard)
    refute "-ac" in command
  end

  test "reports an external player failure to its owner" do
    log =
      capture_log(fn ->
        assert {:ok, audio} = Audio.start_link(command: ["sh", "-c", "exit 7"])
        assert_receive {:EXIT, ^audio, {:audio_player_exit, 7}}, 1_000
      end)

    assert log =~ "audio player sh exited with status 7"
  end

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
