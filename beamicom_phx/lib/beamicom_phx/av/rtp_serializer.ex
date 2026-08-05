defmodule BeamicomPhx.AV.RtpSerializer do
  @moduledoc """
  Serializes pre-payloaded `%Membrane.RTP{}` buffers into RTP wire packets for
  transport over UDP. `Membrane.RTP.SessionBin` can't carry AV1, so the relay
  serializes codec-agnostically here and parses with `Membrane.RTP.Parser` on the
  other end. Assigns a fixed SSRC + payload type, a monotonic 16-bit sequence
  number, and an RTP timestamp derived from the buffer PTS and `clock_rate`.
  The RTP marker is taken from `buffer.metadata[:rtp][:marker]` (set by the
  payloaders on the last packet of a frame).

  ## ExRTP API notes (verified against deps/ex_rtp/lib/ex_rtp/packet.ex)
  - `ExRTP.Packet.new(payload, fields)` accepts keyword list with keys:
    `payload_type`, `sequence_number`, `timestamp`, `ssrc`, `marker`, `csrc`, `padding`
  - `ExRTP.Packet.encode/1` returns a binary
  - `ExRTP.Packet.decode/1` returns `{:ok, packet}` or `{:error, :not_enough_data}`
  """
  use Membrane.Filter

  def_options(
    ssrc: [spec: non_neg_integer()],
    payload_type: [spec: 0..127],
    clock_rate: [spec: pos_integer()]
  )

  def_input_pad(:input, accepted_format: %Membrane.RTP{})
  def_output_pad(:output, accepted_format: %Membrane.RemoteStream{type: :packetized})

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{ssrc: opts.ssrc, pt: opts.payload_type, clock_rate: opts.clock_rate, seq: 0}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{type: :packetized}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    marker = get_in(buffer.metadata, [:rtp, :marker]) || false
    timestamp = rem(div((buffer.pts || 0) * state.clock_rate, 1_000_000_000), 0x1_0000_0000)

    packet =
      ExRTP.Packet.new(buffer.payload,
        payload_type: state.pt,
        sequence_number: state.seq,
        timestamp: timestamp,
        ssrc: state.ssrc,
        marker: marker
      )

    out = %Membrane.Buffer{payload: ExRTP.Packet.encode(packet), pts: buffer.pts}
    {[buffer: {:output, out}], %{state | seq: rem(state.seq + 1, 0x1_0000)}}
  end
end
