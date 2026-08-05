defmodule BeamicomPhx.AV.Av1PayloaderTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  @w 256
  @h 240

  test "AV1 temporal units become RTP buffers with a marked final packet" do
    frame = :binary.copy(<<128>>, @w * @h + 2 * (div(@w, 2) * div(@h, 2)))

    # Encoder NIF requires pts to be an integer (nil causes unifex_parse_arg error)
    frame_duration = Membrane.Time.seconds(1) |> div(60)

    buffers =
      Enum.map(0..2, fn i ->
        %Membrane.Buffer{payload: frame, pts: i * frame_duration}
      end)

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:src, %Testing.Source{
            output: buffers,
            stream_format: %Membrane.RawVideo{
              width: @w,
              height: @h,
              pixel_format: :I420,
              framerate: {60, 1},
              aligned: true
            }
          })
          |> child(:enc, %Membrane.AV1.Encoder{
            real_time_coding: true,
            encoder_mode: 10,
            approx_framerate: {60, 1}
          })
          |> child(:pay, BeamicomPhx.AV.Av1Payloader)
          |> child(:sink, Testing.Sink)
        ]
      )

    assert_sink_stream_format(pipeline, :sink, %Membrane.RTP{})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{metadata: %{rtp: %{marker: _}}})
    Testing.Pipeline.terminate(pipeline)
  end
end
