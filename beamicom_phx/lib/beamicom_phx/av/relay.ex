defmodule BeamicomPhx.AV.Relay do
  @moduledoc """
  Client-side relay: receive the server's AV1/Opus RTP over UDP, forward raw
  `%Membrane.RTP{}` buffers to each browser's `Membrane.WebRTC.Sink` (with
  `payload_rtp: false`), and fan out to one sink per browser.

  Browsers attach with `add_browser/3` from their LiveView; the Relay monitors the
  LiveView pid and removes that browser's sink on `:DOWN` (reliable teardown that
  does not depend on LiveView `terminate/2`).

  ## Source-side pipeline

  UDP.Source (video, port) → Membrane.RTP.Parser → Membrane.Tee (:video_tee)
  UDP.Source (audio, port+2) → Membrane.RTP.Parser → Membrane.Tee (:audio_tee)

  Both Tees are created at init, so browsers can attach immediately — no queuing
  machinery is needed.

  The server sends video on `listen_port` (PT 96, AV1) and audio on
  `listen_port + 2` (PT 111, Opus). `Membrane.RTP.Parser` emits `%RTP{}` buffers
  whose `metadata.rtp` carries the RTP header (timestamp, sequence_number, marker,
  etc.). `Membrane.WebRTC.Sink` with `payload_rtp: false` accepts these directly and
  re-packetizes per browser (reading `buffer.payload` + `metadata.rtp.marker`).

  ## Pad choice: `:push_output` on `Membrane.Tee`

  `Membrane.Tee` has `:output` (pull/auto — slowest consumer back-pressures everyone)
  and `:push_output` (push — forwarded regardless of demand). RTP over UDP is a push
  source with no back-pressure, so the fan-out uses `:push_output`; otherwise one slow
  browser sink would stall the whole relay.
  Source: `deps/membrane_core/lib/membrane/tee.ex`.
  """
  use Membrane.Pipeline

  alias Membrane.{RTP, UDP}

  @name __MODULE__

  def start_link(opts), do: Membrane.Pipeline.start_link(__MODULE__, opts, name: @name)

  @doc "Attach a browser: link a WebRTC.Sink (using `signaling`) to the relayed A/V."
  @spec add_browser(term(), pid(), term()) :: :ok
  def add_browser(browser_id, lv_pid, signaling),
    do: Membrane.Pipeline.call(@name, {:add_browser, browser_id, lv_pid, signaling})

  @impl true
  def handle_init(_ctx, opts) do
    port = Keyword.fetch!(opts, :listen_port)

    # RtpPts restores buffer PTS from the parsed RTP timestamp — RTP.Parser leaves it
    # nil, and the payload_rtp:false WebRTC.Sink crashes without one.
    spec = [
      child(:udp_video, %UDP.Source{local_port_no: port})
      |> child(:video_parser, RTP.Parser)
      |> child(:video_pts, %BeamicomPhx.AV.RtpPts{clock_rate: 90_000})
      |> child(:video_tee, Membrane.Tee),
      child(:udp_audio, %UDP.Source{local_port_no: port + 2})
      |> child(:audio_parser, RTP.Parser)
      |> child(:audio_pts, %BeamicomPhx.AV.RtpPts{clock_rate: 48_000})
      |> child(:audio_tee, Membrane.Tee)
    ]

    {[spec: spec], %{browsers: %{}}}
  end

  def handle_child_notification(_msg, _child, _ctx, state), do: {[], state}

  # handle_call must return {[reply: value | other_actions], state}; the reply action
  # unblocks the caller. Source: deps/membrane_core/lib/membrane/pipeline/action.ex
  @impl true
  def handle_call({:add_browser, id, lv_pid, signaling}, _ctx, state) do
    Process.monitor(lv_pid)

    {[reply: :ok, spec: browser_spec(id, signaling)], put_in(state, [:browsers, lv_pid], id)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, lv_pid, _reason}, _ctx, state) do
    case Map.pop(state.browsers, lv_pid) do
      {nil, _} -> {[], state}
      {id, browsers} -> {[remove_children: [{:sink, id}]], %{state | browsers: browsers}}
    end
  end

  # Children + links to attach one browser's WebRTC.Sink to both Tees.
  # The RTP.Parser already produced %RTP{} buffers, so no depayloader/parser sits
  # between Tee and sink. `payload_rtp: false` tells the sink to forward the RTP
  # payload and marker directly without re-payloading.
  defp browser_spec(id, signaling) do
    sink = {:sink, id}

    [
      child(sink, %Membrane.WebRTC.Sink{
        signaling: signaling,
        tracks: [:audio, :video],
        video_codec: :av1,
        payload_rtp: false
      }),
      get_child(:video_tee)
      |> via_out(Pad.ref(:push_output, id))
      |> via_in(Pad.ref(:input, {id, :video}), options: [kind: :video])
      |> get_child(sink),
      get_child(:audio_tee)
      |> via_out(Pad.ref(:push_output, id))
      |> via_in(Pad.ref(:input, {id, :audio}), options: [kind: :audio])
      |> get_child(sink)
    ]
  end
end
