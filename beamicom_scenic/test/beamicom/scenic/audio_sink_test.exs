defmodule Beamicom.Scenic.AudioSinkTest do
  # Shares the application-started Output.
  use ExUnit.Case, async: false

  alias Beamicom.Host.{AudioChunk, Output}
  alias Beamicom.Scenic.{AudioSink, Screen}

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

  test "holds initial PCM until the prebuffer duration is full" do
    pid =
      start_supervised!(
        {AudioSink,
         command: ["cat"],
         name: :gated_audio_sink,
         audio: %{sample_rate: 1_000, channels: 1, sample_format: :s16le},
         prebuffer_ms: 2}
      )

    first = <<100::signed-little-16>>
    second = <<-100::signed-little-16>>

    send(pid, {:audio, 1, first})
    assert %{ready?: false, pending: [^first], pending_frames: 1} = :sys.get_state(pid)

    send(pid, {:frame, 0})
    assert %{ready?: false, pending: [^first]} = :sys.get_state(pid)

    send(pid, {:audio, 1, second})
    assert %{ready?: true, pending: []} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "accepts typed stereo chunks from the Game Boy host output" do
    output = start_supervised!({Output, name: nil})

    pid =
      start_supervised!(
        {AudioSink,
         command: ["cat"],
         name: :test_gbc_audio_sink,
         output: output,
         audio: %{sample_rate: 44_100, channels: 2, sample_format: :s16le}}
      )

    chunk = %AudioChunk{
      system: :gbc,
      sample_rate: 44_100,
      channels: 2,
      sample_format: :s16le,
      frame_count: 2,
      data: <<1::signed-little-16, 2::signed-little-16, 3::signed-little-16, 4::signed-little-16>>
    }

    Output.publish_audio(output, chunk)
    :sys.get_state(output)
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "prebuffers typed 32 kHz stereo chunks from the SNES host output" do
    output = start_supervised!({Output, name: nil})

    pid =
      start_supervised!(
        {AudioSink,
         command: ["sh", "-c", "cat >/dev/null"],
         name: :test_snes_audio_sink,
         output: output,
         audio: %{sample_rate: 32_000, channels: 2, sample_format: :s16le},
         prebuffer_ms: 1}
      )

    pcm = :binary.copy(<<1::signed-little-16, -1::signed-little-16>>, 32)

    Output.publish_audio(output, %AudioChunk{
      system: :snes,
      sample_rate: 32_000,
      channels: 2,
      sample_format: :s16le,
      frame_count: 32,
      data: pcm
    })

    :sys.get_state(output)

    assert %{ready?: true, pending: [], audio: %{sample_rate: 32_000, channels: 2}} =
             :sys.get_state(pid)
  end

  test "builds mono and stereo player commands from core capabilities" do
    assert "mono" in AudioSink.default_command(1.0)

    assert "stereo" in AudioSink.default_command(1.0, %{
             sample_rate: 44_100,
             channels: 2,
             sample_format: :s16le
           })

    assert ["ffmpeg" | command] =
             AudioSink.default_command(
               1.0,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
               {:unix, :darwin}
             )

    assert "audiotoolbox" in command

    assert ["ffplay" | slow_command] =
             AudioSink.default_command(
               0.1,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
               {:unix, :linux}
             )

    assert Enum.find(slow_command, &String.starts_with?(&1, "atempo=")) ==
             "atempo=0.5,atempo=0.5,atempo=0.5,atempo=0.8"

    assert ["ffplay" | fast_command] =
             AudioSink.default_command(
               200,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
               {:unix, :linux}
             )

    assert "atempo=100,atempo=2.0" in fast_command
  end

  test "retains legacy audio and Scenic module APIs" do
    assert Beamicom.NES.AudioSink.default_command(1.0) == AudioSink.default_command(1.0)
    assert Beamicom.NES.Scenic.Screen.controls_height(:nes) == Screen.controls_height(:nes)
    assert Beamicom.NES.Scenic.Assets.library() == Beamicom.Scenic.Assets.library()
  end

  test "legacy audio start retains its registered process name" do
    pid = start_supervised!({Beamicom.NES.AudioSink, command: ["cat"]})
    assert Process.whereis(Beamicom.NES.AudioSink) == pid
  end
end
