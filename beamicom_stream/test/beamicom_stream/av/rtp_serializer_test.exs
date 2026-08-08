defmodule BeamicomStream.AV.RtpSerializerTest do
  use ExUnit.Case, async: true

  alias BeamicomStream.AV.RtpSerializer

  test "serializes payload type, timestamp, marker, and sequence number" do
    opts = %RtpSerializer{ssrc: 123, payload_type: 96, clock_rate: 90_000}
    {[], state} = RtpSerializer.handle_init(nil, opts)

    input = %Membrane.Buffer{
      payload: "frame",
      pts: 1_000_000_000,
      metadata: %{rtp: %{marker: true}}
    }

    {[buffer: {:output, output}], next_state} =
      RtpSerializer.handle_buffer(:input, input, nil, state)

    assert {:ok, packet} = ExRTP.Packet.decode(output.payload)
    assert packet.payload == "frame"
    assert packet.payload_type == 96
    assert packet.timestamp == 90_000
    assert packet.sequence_number == 0
    assert packet.marker
    assert next_state.seq == 1
  end
end
