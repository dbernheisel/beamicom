defmodule BeamicomV4L2.UCityCompatTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{AudioChunk, Output, VideoFrame}
  alias BeamicomV4L2.{Runtime, Video}

  @moduletag :ucity

  test "uCity crosses the V4L2 host runtime and AV adapter boundary" do
    path = System.get_env("BEAMICOM_UCITY_ROM", "/tmp/ucity_compat.gbc")
    assert File.regular?(path), "uCity ROM is unavailable at #{path}"
    assert {:ok, machine} = path |> File.read!() |> GBSystem.load()

    output = start_supervised!({Output, []})
    :ok = Output.subscribe(output)

    _runtime =
      start_supervised!({Runtime, machine: machine, output: output, pace: true})

    assert_receive {:video_frame, :gbc, _number}, 5_000
    assert %VideoFrame{width: 160, height: 144} = frame = Output.latest_video(output)
    assert byte_size(Video.rgb_payload(frame)) == 160 * 144 * 3

    assert_receive {:audio_chunk,
                    %AudioChunk{
                      channels: 2,
                      sample_format: :s16le,
                      frame_count: frame_count,
                      data: pcm
                    }},
                   5_000

    assert frame_count > 0
    assert byte_size(pcm) == frame_count * 2 * 2
  end
end
