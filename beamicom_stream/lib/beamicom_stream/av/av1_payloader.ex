defmodule BeamicomStream.AV.Av1Payloader do
  @moduledoc """
  Packetizes AV1 temporal units into RTP payload buffers.

  OBU size fields are removed at this boundary, as recommended by the AV1 RTP
  payload specification. This also keeps fragmented OBUs interoperable with
  receivers that treat an in-band size field as part of each RTP fragment.
  """
  use Membrane.Filter

  require Logger

  alias ExWebRTC.RTP.AV1.{OBU, Payload}

  @max_payload_size 1000
  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_tile_list 8

  def_input_pad(:input, accepted_format: %Membrane.AV1{alignment: :tu})
  def_output_pad(:output, accepted_format: %Membrane.RTP{})

  @impl true
  def handle_init(_ctx, _opts), do: {[], nil}

  @impl true
  def handle_stream_format(:input, _format, _ctx, state),
    do: {[stream_format: {:output, %Membrane.RTP{}}], state}

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    buffers =
      buffer.payload
      |> packetize()
      |> Enum.map(fn packet ->
        %Membrane.Buffer{
          payload: packet.payload,
          pts: buffer.pts,
          metadata: %{rtp: %{marker: packet.marker}}
        }
      end)

    {[buffer: {:output, buffers}], state}
  end

  @doc false
  def packetize(temporal_unit) when is_binary(temporal_unit) and temporal_unit != <<>> do
    temporal_unit
    |> packetize_obus([])
    |> Enum.reverse()
    |> List.update_at(-1, &%{&1 | marker: true})
  end

  defp packetize_obus(<<>>, packets), do: packets

  defp packetize_obus(temporal_unit, packets) do
    case OBU.parse(temporal_unit) do
      {:ok, %OBU{type: type}, rest} when type in [@obu_temporal_delimiter, @obu_tile_list] ->
        packetize_obus(rest, packets)

      {:ok, obu, rest} ->
        packets =
          obu
          |> OBU.disable_dropping_in_decoder_if_applicable()
          |> clear_size_field()
          |> OBU.serialize()
          |> chunk_obu(@max_payload_size - 1, [])
          |> Payload.payload_obu_fragments(new_coded_sequence_bit(obu))
          |> Enum.reduce(packets, fn payload, packets ->
            [ExRTP.Packet.new(Payload.serialize(payload)) | packets]
          end)

        packetize_obus(rest, packets)

      {:error, :invalid_av1_bitstream} ->
        Logger.warning(
          "Unable to parse OBU from invalid AV1 bitstream; dropping temporal-unit tail"
        )

        packets
    end
  end

  defp chunk_obu(obu, max_size, chunks) when byte_size(obu) <= max_size,
    do: Enum.reverse([obu | chunks])

  defp chunk_obu(obu, max_size, chunks) do
    <<chunk::binary-size(^max_size), rest::binary>> = obu
    chunk_obu(rest, max_size, [chunk | chunks])
  end

  defp clear_size_field(%OBU{} = obu), do: %{obu | s: 0}

  defp new_coded_sequence_bit(%OBU{type: @obu_sequence_header}), do: 1
  defp new_coded_sequence_bit(%OBU{}), do: 0
end
