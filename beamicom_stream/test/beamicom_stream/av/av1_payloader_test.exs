defmodule BeamicomStream.AV.Av1PayloaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias BeamicomStream.AV.Av1Payloader
  alias ExWebRTC.RTP.AV1.OBU

  test "fragmented OBUs use canonical size-free headers and continuous fragment flags" do
    payload = :binary.copy(<<0xA5>>, 2_500)
    temporal_unit = OBU.serialize(%OBU{type: 6, x: 0, s: 1, payload: payload})

    packets = Av1Payloader.packetize(temporal_unit)

    assert [first, middle, last] = packets
    assert <<0::1, 1::1, 1::2, 0::1, 0::3, first_obu::binary>> = first.payload
    assert <<1::1, 1::1, 1::2, 0::1, 0::3, middle_obu::binary>> = middle.payload
    assert <<1::1, 0::1, 1::2, 0::1, 0::3, last_obu::binary>> = last.payload
    assert <<0::1, 6::4, 0::1, 0::1, 0::1, _::binary>> = first_obu
    assert first.marker == false
    assert middle.marker == false
    assert last.marker == true
    assert Enum.all?(packets, &(byte_size(&1.payload) <= 1_000))

    assert first_obu <> middle_obu <> last_obu ==
             <<0::1, 6::4, 0::1, 0::1, 0::1, payload::binary>>
  end

  test "a sequence header is aggregated with its keyframe" do
    sequence_header = OBU.serialize(%OBU{type: 1, x: 0, s: 1, payload: <<1, 2, 3>>})
    frame = OBU.serialize(%OBU{type: 6, x: 0, s: 1, payload: <<4, 5, 6>>})

    assert [packet] = Av1Payloader.packetize(sequence_header <> frame)

    assert <<0::1, 0::1, 2::2, 1::1, 0::3, sequence_size, payload::binary>> =
             packet.payload

    assert sequence_size == 4
    assert <<sequence::binary-size(^sequence_size), transmitted_frame::binary>> = payload
    assert <<0::1, 1::4, 0::1, 0::1, 0::1, 1, 2, 3>> = sequence
    assert <<0::1, 6::4, 0::1, 0::1, 0::1, 4, 5, 6>> = transmitted_frame
    assert packet.marker
  end

  test "a sequence header and fragmented keyframe remain one RTP frame" do
    sequence_header = OBU.serialize(%OBU{type: 1, x: 0, s: 1, payload: <<1, 2, 3>>})
    frame_payload = :binary.copy(<<0xA5>>, 2_500)
    frame = OBU.serialize(%OBU{type: 6, x: 0, s: 1, payload: frame_payload})

    assert [first, middle, last] = Av1Payloader.packetize(sequence_header <> frame)
    assert <<0::1, 1::1, 2::2, 1::1, 0::3, sequence_size, first_payload::binary>> = first.payload
    assert <<1::1, 1::1, 1::2, 0::1, 0::3, middle_payload::binary>> = middle.payload
    assert <<1::1, 0::1, 1::2, 0::1, 0::3, last_payload::binary>> = last.payload

    assert <<_sequence::binary-size(^sequence_size), first_frame_fragment::binary>> =
             first_payload

    assert first_frame_fragment <> middle_payload <> last_payload ==
             <<0::1, 6::4, 0::1, 0::1, 0::1, frame_payload::binary>>

    refute first.marker
    refute middle.marker
    assert last.marker
  end

  test "the 999-byte OBU fragment boundary keeps every RTP payload at 1000 bytes or less" do
    for {obu_payload_size, normalized_obu_size, packet_sizes} <- [
          {997, 998, [999]},
          {998, 999, [1_000]},
          {999, 1_000, [1_000, 2]}
        ] do
      temporal_unit = obu(6, :binary.copy(<<0xA5>>, obu_payload_size))
      packets = Av1Payloader.packetize(temporal_unit)

      assert Enum.map(packets, &byte_size(&1.payload)) == packet_sizes
      assert Enum.sum(packet_sizes) - length(packet_sizes) == normalized_obu_size
      assert Enum.all?(packets, &(byte_size(&1.payload) <= 1_000))
    end
  end

  test "temporal delimiter and tile-list OBUs are not transmitted" do
    temporal_delimiter = obu(2, <<>>)
    tile_list = obu(8, <<0xAA>>)
    frame = obu(6, <<1, 2, 3>>)

    assert [] = Av1Payloader.packetize(temporal_delimiter <> tile_list)
    assert [packet] = Av1Payloader.packetize(temporal_delimiter <> tile_list <> frame)
    assert <<0::1, 0::1, 1::2, 0::1, 0::3, transmitted_obu::binary>> = packet.payload
    assert transmitted_obu == <<0::1, 6::4, 0::1, 0::1, 0::1, 1, 2, 3>>
    assert packet.marker
  end

  test "sequence headers retain the decoder-drop prevention rewrite" do
    sequence_payload = <<3::3, 0::3, 1::1, 0::5, 0x123::12, 0::5, 5::3>>

    assert [packet] = Av1Payloader.packetize(obu(1, sequence_payload))
    assert <<0::1, 0::1, 1::2, 1::1, 0::3, transmitted_obu::binary>> = packet.payload
    assert {:ok, %OBU{s: 0, payload: rewritten_payload}, <<>>} = OBU.parse(transmitted_obu)
    assert rewritten_payload == <<3::3, 0::3, 1::1, 0::5, 0xFFF::12, 0::5, 5::3>>
  end

  test "OBU extension headers survive canonicalization" do
    temporal_unit =
      OBU.serialize(%OBU{type: 6, x: 1, s: 1, tid: 5, sid: 2, payload: <<1, 2, 3>>})

    assert [packet] = Av1Payloader.packetize(temporal_unit)
    assert <<_aggregation_header, transmitted_obu::binary>> = packet.payload

    assert {:ok, %OBU{x: 1, s: 0, tid: 5, sid: 2, payload: <<1, 2, 3>>}, <<>>} =
             OBU.parse(transmitted_obu)
  end

  test "malformed-only and truncated temporal units produce no packets" do
    truncated = <<0::1, 6::4, 0::1, 1::1, 0::1>>

    {results, log} =
      with_log(fn ->
        {Av1Payloader.packetize(<<0xFF>>), Av1Payloader.packetize(truncated)}
      end)

    assert results == {[], []}
    assert log =~ "dropping temporal-unit tail"
  end

  test "a malformed tail leaves the last valid fragment marked" do
    valid = obu(6, :binary.copy(<<0x5A>>, 2_500))

    {packets, log} = with_log(fn -> Av1Payloader.packetize(valid <> <<0xFF>>) end)

    assert [_first, _middle, last] = packets
    assert Enum.count(packets, & &1.marker) == 1
    assert last.marker
    assert log =~ "dropping temporal-unit tail"
  end

  defp obu(type, payload) do
    OBU.serialize(%OBU{type: type, x: 0, s: 1, payload: payload})
  end
end
