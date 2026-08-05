defmodule BeamicomPhx.AV.RtpSerializerTest do
  use ExUnit.Case, async: false
  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  test "serializes RTP buffers to decodable wire packets with marker + incrementing seq" do
    buffers = [
      %Membrane.Buffer{payload: <<1, 2, 3>>, pts: 0, metadata: %{rtp: %{marker: false}}},
      %Membrane.Buffer{payload: <<4, 5, 6>>, pts: 1_000_000, metadata: %{rtp: %{marker: true}}}
    ]

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:src, %Testing.Source{
            output: buffers,
            stream_format: %Membrane.RTP{}
          })
          |> child(:ser, %BeamicomPhx.AV.RtpSerializer{
            ssrc: 12345,
            payload_type: 96,
            clock_rate: 90_000
          })
          |> child(:sink, Testing.Sink)
        ]
      )

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: p1})
    assert {:ok, pkt1} = ExRTP.Packet.decode(p1)
    assert pkt1.payload == <<1, 2, 3>>
    assert pkt1.ssrc == 12345
    assert pkt1.payload_type == 96
    assert pkt1.marker == false

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: p2})
    assert {:ok, pkt2} = ExRTP.Packet.decode(p2)
    assert pkt2.marker == true
    assert pkt2.sequence_number == pkt1.sequence_number + 1

    Testing.Pipeline.terminate(pipeline)
  end
end
