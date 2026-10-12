defmodule Beamicom.Scenic.AudioSinkTest do
  # Shares the application-started Output.
  use ExUnit.Case, async: false

  alias Beamicom.Host.{AudioChunk, Output}
  alias Beamicom.Scenic.{AudioSink, Screen}

  @discard_command ["sh", "-c", "cat >/dev/null"]
  @unacknowledged_packet_command ["sh", "-c", "cat >/dev/null", "packet4"]

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

  test "keeps a small default startup reserve" do
    pid = start_supervised!({AudioSink, command: @discard_command, name: :buffered_audio_sink})

    assert %{ready?: false, prebuffer_frames: 1_764} = :sys.get_state(pid)
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

  test "retains every typed stereo chunk from a core-owned host output" do
    output = start_supervised!({Output, name: nil})

    pid =
      start_supervised!(
        {AudioSink,
         command: @discard_command,
         name: :test_gbc_audio_sink,
         output: output,
         prebuffer_ms: 0,
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

    :sys.suspend(pid)

    for sample <- 1..100 do
      Output.publish_audio(output, %{chunk | data: stereo_sample(sample)})
    end

    :sys.get_state(output)

    assert {:message_queue_len, 100} = Process.info(pid, :message_queue_len)

    :sys.resume(pid)
    :sys.get_state(pid)

    assert Process.alive?(pid)

    output_state = :sys.get_state(output)
    assert output_state.audio[pid] == :envelope
    refute MapSet.member?(output_state.latest_audio_subscribers, pid)
    refute MapSet.member?(output_state.audio_notifications, pid)
  end

  test "bounds native audio waiting for a stalled player and retains the newest PCM" do
    audio = %{sample_rate: 1_000, channels: 1, sample_format: :s16le}

    pid =
      start_supervised!(
        {AudioSink,
         command: @unacknowledged_packet_command,
         name: :bounded_audio_sink,
         audio: audio,
         prebuffer_ms: 0}
      )

    chunks =
      for sample <- 1..100 do
        pcm = :binary.copy(<<sample::signed-little-16>>, 20)
        send(pid, {:audio, 20, pcm})
        pcm
      end

    state = :sys.get_state(pid)

    assert state.in_flight?
    assert state.max_outbox_bytes == 80
    assert state.outbox_bytes == 80
    assert state.dropped_audio_frames == 1_940

    assert [{second_last, 40}, {last, 40}] = :queue.to_list(state.outbox)
    assert second_last == Enum.at(chunks, -2)
    assert last == List.last(chunks)
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

  test "uses the bounded native player for normal-speed playback when it was built" do
    audio = %{sample_rate: 44_100, channels: 1, sample_format: :s16le}
    command = AudioSink.default_command(1.0, audio, {:unix, :darwin})
    native = Application.app_dir(:beamicom_scenic, "priv/native/audio_player")

    if File.regular?(native) do
      assert command == [native, "44100", "1", "40", "packet4"]
    else
      assert ["ffplay" | _args] = command
    end
  end

  test "builds low-buffer ffplay fallback commands from core capabilities" do
    assert ["ffplay" | mono_command] = AudioSink.ffplay_command(1.0)
    assert "mono" in mono_command

    assert ["ffplay" | macos_command] =
             AudioSink.ffplay_command(
               1.0,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le}
             )

    assert "stereo" in macos_command
    assert "direct" in macos_command
    assert "nobuffer" in macos_command
    assert Enum.at(macos_command, Enum.find_index(macos_command, &(&1 == "-ar")) + 1) == "8000"
    assert "asetrate=44100,asetpts=N/SR/TB" in macos_command

    assert ["ffplay" | snes_command] =
             AudioSink.ffplay_command(
               1.0,
               %{sample_rate: 32_000, channels: 2, sample_format: :s16le}
             )

    assert "asetrate=32000,asetpts=N/SR/TB" in snes_command

    assert ["ffplay" | slow_command] =
             AudioSink.default_command(
               0.1,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
               {:unix, :linux}
             )

    assert "stereo" in slow_command

    assert "asetrate=44100,asetpts=N/SR/TB,atempo=0.5,atempo=0.5,atempo=0.5,atempo=0.8" in slow_command

    assert ["ffplay" | fast_command] =
             AudioSink.default_command(
               200,
               %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
               {:unix, :linux}
             )

    assert "asetrate=44100,asetpts=N/SR/TB,atempo=100,atempo=2.0" in fast_command
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

  defp stereo_sample(sample) do
    <<sample::signed-little-16, -sample::signed-little-16, sample::signed-little-16,
      -sample::signed-little-16>>
  end
end
