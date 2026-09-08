defmodule BeamicomStream.AV.AudioSourceTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.AudioChunk
  alias BeamicomStream.AV.AudioSource

  test "accepts stereo envelopes and advances PTS in sample frames" do
    state = %{
      count: 0,
      owner: nil,
      output: self(),
      channels: 2,
      sample_rate: 44_100,
      sample_format: :s16le
    }

    first = chunk(441, :binary.copy(<<1, 0, 2, 0>>, 441))

    assert {[buffer: {:output, %Membrane.Buffer{payload: payload, pts: 0}}], state} =
             AudioSource.handle_info({:audio_chunk, first}, nil, state)

    assert payload == first.data
    assert state.count == 441

    second = chunk(220, :binary.copy(<<3, 0, 4, 0>>, 220))

    assert {[buffer: {:output, %Membrane.Buffer{pts: pts}}], state} =
             AudioSource.handle_info({:audio_chunk, second}, nil, state)

    assert pts == 10_000_000
    assert state.count == 661
  end

  test "ignores envelopes that do not match the negotiated PCM format" do
    state = %{
      count: 7,
      owner: nil,
      output: self(),
      channels: 2,
      sample_rate: 44_100,
      sample_format: :s16le
    }

    for mismatch <- [
          %{chunk(1, <<0, 0, 0, 0>>) | channels: 1},
          %{chunk(1, <<0, 0, 0, 0>>) | sample_rate: 48_000},
          %{chunk(1, <<0, 0, 0, 0>>) | sample_format: :s24le}
        ] do
      assert {[], ^state} = AudioSource.handle_info({:audio_chunk, mismatch}, nil, state)
    end
  end

  defp chunk(frames, data) do
    %AudioChunk{
      system: :gbc,
      sample_rate: 44_100,
      channels: 2,
      sample_format: :s16le,
      frame_count: frames,
      data: data
    }
  end
end
