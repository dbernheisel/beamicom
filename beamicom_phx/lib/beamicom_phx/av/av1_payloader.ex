defmodule BeamicomPhx.AV.Av1Payloader do
  @moduledoc """
  Packetizes AV1 temporal units into RTP payloads for `Membrane.WebRTC.Sink`
  running in `payload_rtp: false` mode.

  There is no Membrane RTP AV1 payloader element, but ex_webrtc ships the RTP
  packetization logic (`ExWebRTC.RTP.Payloader.AV1`). This wraps it: each input
  `%Membrane.AV1{alignment: :tu}` buffer becomes one or more `%Membrane.RTP{}`
  buffers whose payload is an AV1 RTP payload, with the RTP marker (set on the
  temporal unit's last packet) carried in `metadata.rtp.marker` — the only RTP
  field the sink reads before generating its own sequence numbers/timestamps.
  """
  use Membrane.Filter

  @max_payload_size 1000

  def_input_pad(:input, accepted_format: %Membrane.AV1{alignment: :tu})
  def_output_pad(:output, accepted_format: %Membrane.RTP{})

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{payloader: ExWebRTC.RTP.Payloader.AV1.new(@max_payload_size)}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %Membrane.RTP{}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {packets, payloader} = ExWebRTC.RTP.Payloader.AV1.payload(state.payloader, buffer.payload)

    buffers =
      Enum.map(packets, fn packet ->
        %Membrane.Buffer{
          payload: packet.payload,
          pts: buffer.pts,
          metadata: %{rtp: %{marker: packet.marker}}
        }
      end)

    {[buffer: {:output, buffers}], %{state | payloader: payloader}}
  end
end
