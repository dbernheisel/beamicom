defmodule BeamicomStream.AV.Av1Payloader do
  @moduledoc "Packetizes AV1 temporal units into RTP payload buffers."
  use Membrane.Filter

  @max_payload_size 1000

  def_input_pad(:input, accepted_format: %Membrane.AV1{alignment: :tu})
  def_output_pad(:output, accepted_format: %Membrane.RTP{})

  @impl true
  def handle_init(_ctx, _opts),
    do: {[], %{payloader: ExWebRTC.RTP.Payloader.AV1.new(@max_payload_size)}}

  @impl true
  def handle_stream_format(:input, _format, _ctx, state),
    do: {[stream_format: {:output, %Membrane.RTP{}}], state}

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
