defmodule Beamicom.Host.OutputTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.{AudioChunk, Output, VideoFrame}

  test "child specs distinguish named output hubs" do
    assert %{id: {Output, :first_output}} = Output.child_spec(name: :first_output)
    assert %{id: {Output, :second_output}} = Output.child_spec(name: :second_output)
  end

  test "coalesces video and streams audio using neutral envelopes" do
    output = start_supervised!({Output, name: nil})
    assert :ok = Output.subscribe(output)

    frame = %VideoFrame{
      system: :test,
      number: 4,
      width: 2,
      height: 1,
      pixel_format: :rgb24,
      data: <<1, 2, 3, 4, 5, 6>>
    }

    chunk = %AudioChunk{
      system: :test,
      sample_rate: 48_000,
      channels: 2,
      sample_format: :s16le,
      frame_count: 2,
      data: <<0::64>>
    }

    assert :ok = Output.publish_video(output, frame)
    assert_receive {:video_frame, :test, 4}
    assert ^frame = Output.latest_video(output)

    assert :ok = Output.publish_audio(output, chunk)
    assert_receive {:audio_chunk, ^chunk}
  end

  test "legacy notifications preserve the existing NES-shaped protocol" do
    output = start_supervised!({Output, name: nil})
    assert :ok = Output.subscribe(output, :legacy)

    frame = %VideoFrame{
      system: :test,
      number: 7,
      width: 1,
      height: 1,
      pixel_format: :rgb24,
      data: <<0, 0, 0>>
    }

    chunk = %AudioChunk{
      system: :test,
      sample_rate: 44_100,
      channels: 1,
      sample_format: :s16le,
      frame_count: 1,
      data: <<1::signed-little-16>>
    }

    Output.publish_video(output, frame)
    Output.publish_audio(output, chunk)

    assert_receive {:frame, 7}
    assert_receive {:audio, 1, <<1::signed-little-16>>}
  end

  test "empty audio chunks are not delivered" do
    output = start_supervised!({Output, name: nil})
    Output.subscribe_audio(output)

    Output.publish_audio(output, %AudioChunk{
      system: :test,
      sample_rate: 44_100,
      channels: 1,
      sample_format: :s16le,
      frame_count: 0,
      data: <<>>
    })

    refute_receive {:audio_chunk, _chunk}
  end

  test "keeps at most one video notification pending until the subscriber reads" do
    output = start_supervised!({Output, name: nil})
    assert :ok = Output.subscribe_video(output)

    Enum.each(1..100, fn number -> Output.publish_video(output, frame(number)) end)

    assert_receive {:video_frame, :test, 1}
    assert %VideoFrame{number: 100} = Output.latest_video(output)
    refute_receive {:video_frame, :test, _number}

    Output.publish_video(output, frame(101))
    assert_receive {:video_frame, :test, 101}
  end

  defp frame(number) do
    %VideoFrame{
      system: :test,
      number: number,
      width: 1,
      height: 1,
      pixel_format: :rgb24,
      data: <<number::24>>
    }
  end
end
