defmodule BeamicomPhx.AV.RtpBroadcast do
  @moduledoc """
  Server-side broadcast: encode the emulator's A/V once and send it as RTP over
  UDP to the client node. Runs persistently in server mode when a target is set,
  independent of the per-browser WebRTC pipelines.

  Uses a codec-agnostic path: AV1 and Opus are packetized by their respective
  payloaders into `%Membrane.RTP{}` buffers, then serialized to wire RTP by
  `BeamicomPhx.AV.RtpSerializer` before going to UDP.Sink — no SessionBin needed.
  Video goes to `port`, audio to `port + 2`.
  """
  use Membrane.Pipeline

  alias Membrane.UDP

  @video_ssrc 111_111
  @audio_ssrc 222_222

  @impl true
  def handle_init(_ctx, opts) do
    {ip, port} = Keyword.fetch!(opts, :target)

    spec = [
      # Video: emulator RGB -> I420 -> AV1 (SVT, real-time, quality) -> RTP payload -> serialize -> UDP
      child(:video_src, BeamicomPhx.AV.VideoSource)
      |> child(:scaler, %Membrane.FFmpeg.SWScale.Converter{format: :I420})
      |> child(:av1, %Membrane.AV1.Encoder{
        real_time_coding: true,
        encoder_mode: 8,
        rate_control: {:crf, 20},
        approx_framerate: {60, 1},
        config_parameters: %{"scm" => "2"}
      })
      |> child(:av1_pay, BeamicomPhx.AV.Av1Payloader)
      |> child(:video_rtp, %BeamicomPhx.AV.RtpSerializer{
        ssrc: @video_ssrc,
        payload_type: 96,
        clock_rate: 90_000
      })
      |> child(:udp_video, %UDP.Sink{destination_address: ip, destination_port_no: port}),

      # Audio: emulator PCM -> 48k -> Opus -> RTP payload -> serialize -> UDP (port + 2)
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
      |> child(:audio_rtp, %BeamicomPhx.AV.RtpSerializer{
        ssrc: @audio_ssrc,
        payload_type: 111,
        clock_rate: 48_000
      })
      |> child(:udp_audio, %UDP.Sink{destination_address: ip, destination_port_no: port + 2})
    ]

    {[spec: spec], %{}}
  end
end
