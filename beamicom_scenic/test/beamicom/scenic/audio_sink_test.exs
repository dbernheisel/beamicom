defmodule Beamicom.Scenic.AudioSinkTest do
  # Shares the application-started Output.
  use ExUnit.Case, async: false

  alias Beamicom.Host.{AudioChunk, Output}
  alias Beamicom.Scenic.{AudioSink, Screen}

  @discard_command ["sh", "-c", "cat >/dev/null"]

  test "streams the first PCM chunk without a startup delay" do
    pid =
      start_supervised!(
        {AudioSink, command: @discard_command, name: :test_audio_sink, prebuffer_ms: 0}
      )

    pcm = <<100::signed-little-16, -100::signed-little-16, 200::signed-little-16>>
    send(pid, {:audio, 3, pcm})
    send(pid, {:frame, 0})
    # Force the mailbox to drain (FIFO), then confirm the sink is still alive.
    assert %{ready?: true, pending: []} = :sys.get_state(pid)
    assert {:priority, :high} = Process.info(pid, :priority)
    assert Process.alive?(pid)
  end

  test "defaults to a short prebuffer for stable realtime playback" do
    pid = start_supervised!({AudioSink, command: @discard_command, name: :buffered_audio_sink})

    assert %{ready?: false, prebuffer_frames: 11_025} = :sys.get_state(pid)
  end

  test "scales signed 16-bit PCM independently of channel layout" do
    pcm =
      <<-32_768::signed-little-16, -101::signed-little-16, 101::signed-little-16,
        32_767::signed-little-16>>

    assert AudioSink.scale_pcm(pcm, 100) == pcm

    assert AudioSink.scale_pcm(pcm, 50) ==
             <<-16_384::signed-little-16, -50::signed-little-16, 50::signed-little-16,
               16_383::signed-little-16>>

    assert AudioSink.scale_pcm(pcm, 0) == :binary.copy(<<0::signed-little-16>>, 4)
  end

  test "updates and validates volume while the sink is running" do
    pid = start_supervised!({AudioSink, command: @discard_command, name: :volume_audio_sink})

    assert :ok = AudioSink.set_volume(pid, 35)
    assert :sys.get_state(pid).volume == 35

    assert {:error, {:invalid_volume, 101}} = AudioSink.set_volume(pid, 101)
    assert :sys.get_state(pid).volume == 35
  end

  test "restarts the external player after emulation is paused" do
    pid =
      start_supervised!(
        {AudioSink, command: @discard_command, name: :pausable_audio_sink, prebuffer_ms: 0}
      )

    first_port = :sys.get_state(pid).port

    assert :ok = AudioSink.pause(pid)
    assert %{port: nil, pending: [], pending_frames: 0} = :sys.get_state(pid)
    refute Port.info(first_port)

    send(pid, {:audio, 1, <<100::signed-little-16>>})
    assert %{port: nil, pending: []} = :sys.get_state(pid)

    assert :ok = AudioSink.resume(pid)
    second_port = :sys.get_state(pid).port
    assert is_port(second_port)
    refute second_port == first_port

    send(pid, {:audio, 1, <<-100::signed-little-16>>})
    assert %{port: ^second_port, ready?: true, pending: []} = :sys.get_state(pid)
  end

  test "holds initial PCM until the prebuffer duration is full" do
    pid =
      start_supervised!(
        {AudioSink,
         command: @discard_command,
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
         command: @discard_command,
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
    refute "direct" in command
    refute "nobuffer" in command
    refute Enum.any?(command, &String.contains?(&1, "asetnsamples"))

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
    pid = start_supervised!({Beamicom.NES.AudioSink, command: @discard_command})
    assert Process.whereis(Beamicom.NES.AudioSink) == pid
  end
end
