defmodule BeamicomV4L2.UCityCompatTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{AudioChunk, Output, VideoFrame}
  alias BeamicomV4L2.{Runtime, Video}

  @moduletag :ucity
  @ucity_rom Path.expand("fixtures/ucity_compat_v1.3.gbc", __DIR__)
  @ucity_sha256 "8b98cbb5303d2159a931332dc375642fb474b2c9473c7ba473ad94c98a8814bf"

  test "uCity crosses the V4L2 host runtime and AV adapter boundary" do
    rom = File.read!(@ucity_rom)

    assert :sha256 |> :crypto.hash(rom) |> Base.encode16(case: :lower) == @ucity_sha256
    assert {:ok, machine} = GBSystem.load(rom)

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
