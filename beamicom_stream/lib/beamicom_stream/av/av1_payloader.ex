defmodule BeamicomStream.AV.Av1Payloader do
  @moduledoc """
  Packetizes AV1 temporal units into RTP payload buffers.

  OBU size fields are removed at this boundary, as recommended by the AV1 RTP
  payload specification. Sequence headers are aggregated with the following
  frame OBU so WebRTC receivers treat the coded-sequence header and keyframe as
  one encoded frame.
  """
  use Membrane.Filter

  require Logger

  alias ExWebRTC.RTP.AV1.{LEB128, OBU, Payload}

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
    |> parse_obus([])
    |> packetize_obus()
    |> List.update_at(-1, &%{&1 | marker: true})
  end

  defp parse_obus(<<>>, obus), do: Enum.reverse(obus)

  defp parse_obus(temporal_unit, obus) do
    case OBU.parse(temporal_unit) do
      {:ok, %OBU{type: type}, rest} when type in [@obu_temporal_delimiter, @obu_tile_list] ->
        parse_obus(rest, obus)

      {:ok, obu, rest} ->
        obu = OBU.disable_dropping_in_decoder_if_applicable(obu)

        parse_obus(rest, [
          %{type: obu.type, data: obu |> clear_size_field() |> OBU.serialize()} | obus
        ])

      {:error, :invalid_av1_bitstream} ->
        Logger.warning(
          "Unable to parse OBU from invalid AV1 bitstream; dropping temporal-unit tail"
        )

        Enum.reverse(obus)
    end
  end

  defp packetize_obus([
         %{type: @obu_sequence_header, data: sequence},
         %{data: next_obu} = next | rest
       ]) do
    case aggregate_sequence_header(sequence, next_obu) do
      {:ok, first_payload, remaining_next_obu} ->
        first_packet = ExRTP.Packet.new(Payload.serialize(first_payload))

        continuation_packets =
          if remaining_next_obu == <<>> do
            []
          else
            remaining_next_obu
            |> chunk_obu(@max_payload_size - 1, [])
            |> continuation_payloads()
            |> Enum.map(&ExRTP.Packet.new(Payload.serialize(&1)))
          end

        [first_packet | continuation_packets] ++ packetize_obus(rest)

      :error ->
        packetize_obu(sequence, 1) ++ packetize_obus([next | rest])
    end
  end

  defp packetize_obus(obus) do
    Enum.flat_map(obus, fn %{type: type, data: obu} ->
      packetize_obu(obu, new_coded_sequence_bit(type))
    end)
  end

  defp packetize_obu(obu, n_bit) do
    obu
    |> chunk_obu(@max_payload_size - 1, [])
    |> Payload.payload_obu_fragments(n_bit)
    |> Enum.map(&ExRTP.Packet.new(Payload.serialize(&1)))
  end

  defp aggregate_sequence_header(sequence, next_obu) do
    encoded_size = sequence |> byte_size() |> LEB128.encode()
    available = @max_payload_size - 1 - byte_size(encoded_size) - byte_size(sequence)

    if available > 0 do
      fragment_size = min(byte_size(next_obu), available)
      <<next_fragment::binary-size(^fragment_size), remaining::binary>> = next_obu

      payload = %Payload{
        z: 0,
        y: if(remaining == <<>>, do: 0, else: 1),
        w: 2,
        n: 1,
        payload: encoded_size <> sequence <> next_fragment
      }

      {:ok, payload, remaining}
    else
      :error
    end
  end

  defp continuation_payloads([]), do: []

  defp continuation_payloads(chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %Payload{
        z: 1,
        y: if(index == length(chunks) - 1, do: 0, else: 1),
        w: 1,
        n: 0,
        payload: chunk
      }
    end)
  end

  defp chunk_obu(obu, max_size, chunks) when byte_size(obu) <= max_size,
    do: Enum.reverse([obu | chunks])

  defp chunk_obu(obu, max_size, chunks) do
    <<chunk::binary-size(^max_size), rest::binary>> = obu
    chunk_obu(rest, max_size, [chunk | chunks])
  end

  defp clear_size_field(%OBU{} = obu), do: %{obu | s: 0}

  defp new_coded_sequence_bit(@obu_sequence_header), do: 1
  defp new_coded_sequence_bit(_type), do: 0
end
