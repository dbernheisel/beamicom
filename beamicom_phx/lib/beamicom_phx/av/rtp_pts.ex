defmodule BeamicomPhx.AV.RtpPts do
  @moduledoc """
  Restores a buffer PTS from the parsed RTP timestamp.

  `Membrane.RTP.Parser` exposes the RTP header timestamp in `metadata.rtp.timestamp`
  but leaves `Membrane.Buffer.pts` nil. `Membrane.WebRTC.Sink` (in `payload_rtp: false`
  mode) needs a PTS — it computes the outgoing RTP timestamp by dividing the PTS by the
  codec timebase — and crashes on nil. Convert the RTP timestamp (in `clock_rate` ticks:
  90 kHz video, 48 kHz audio) back to nanoseconds so the sink can restamp it.
  """
  use Membrane.Filter

  def_options(clock_rate: [spec: pos_integer()])

  def_input_pad(:input, accepted_format: %Membrane.RTP{})
  def_output_pad(:output, accepted_format: %Membrane.RTP{})

  @impl true
  def handle_init(_ctx, opts), do: {[], %{clock_rate: opts.clock_rate}}

  @impl true
  def handle_stream_format(:input, format, _ctx, state),
    do: {[stream_format: {:output, format}], state}

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    ts = get_in(buffer.metadata, [:rtp, :timestamp]) || 0
    pts = div(ts * 1_000_000_000, state.clock_rate)
    {[buffer: {:output, %{buffer | pts: pts}}], state}
  end
end
