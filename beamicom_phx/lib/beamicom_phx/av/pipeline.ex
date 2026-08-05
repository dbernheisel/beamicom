defmodule BeamicomPhx.AV.Pipeline do
  @moduledoc """
  Encodes the emulator's A/V once and sends it to one browser over WebRTC.

  ponytail: one pipeline per browser connection (started by WatchLive). Fine for
  watch-only Phase 1. Upgrade path when multi-viewer/RTP (Phase 2) lands: a single
  shared encoder fanned out with `Membrane.Tee` to per-peer Sinks + the RTP output.

  Video is encoded with SVT-AV1 and pre-payloaded into RTP by `BeamicomPhx.AV.Av1Payloader`
  before reaching the sink (`payload_rtp: false` mode). Audio is pre-payloaded with
  `Membrane.RTP.Opus.Payloader` for the same reason — `payload_rtp` is a sink-wide flag.
  """
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    sink = %Membrane.WebRTC.Sink{
      signaling: Keyword.fetch!(opts, :egress_signaling),
      tracks: [:audio, :video],
      video_codec: :av1,
      payload_rtp: false
    }

    spec = [
      child(:sink, sink),

      # Video: RGB -> I420 -> AV1 (SVT, real-time) -> RTP payload -> sink
      child(:video_src, BeamicomPhx.AV.VideoSource)
      |> child(:scaler, %Membrane.FFmpeg.SWScale.Converter{format: :I420})
      # Bandwidth is a non-issue at 256x240 over LAN, so favor quality: a low CRF
      # (vs the plugin's default 35) and a slower preset (vs 10). NES pixel art also
      # benefits from screen-content coding tools (scm), passed via config_parameters.
      |> child(:av1, %Membrane.AV1.Encoder{
        real_time_coding: true,
        encoder_mode: 8,
        rate_control: {:crf, 20},
        approx_framerate: {60, 1},
        config_parameters: %{"scm" => "2"}
      })
      |> child(:av1_pay, BeamicomPhx.AV.Av1Payloader)
      |> via_in(:input, options: [kind: :video])
      |> get_child(:sink),

      # Audio: 44.1k s16le -> 48k -> Opus -> RTP payload -> sink
      child(:audio_src, BeamicomPhx.AV.AudioSource)
      |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          channels: 1,
          sample_rate: 48_000,
          sample_format: :s16le
        }
      })
      |> child(:opus, Membrane.Opus.Encoder)
      |> child(:opus_pay, Membrane.RTP.Opus.Payloader)
      |> via_in(:input, options: [kind: :audio])
      |> get_child(:sink)
    ]

    {[spec: spec], %{}}
  end
end
