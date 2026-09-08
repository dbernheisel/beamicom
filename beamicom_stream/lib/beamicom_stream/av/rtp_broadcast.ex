defmodule BeamicomStream.AV.RtpBroadcast do
  @moduledoc "Encodes Beamicom video as AV1 and audio as Opus, then broadcasts RTP over UDP."
  use Membrane.Pipeline

  alias BeamicomStream.AV.{AudioSource, Av1Payloader, RtpSerializer, VideoSource}
  alias Membrane.UDP

  @video_ssrc 111_111
  @audio_ssrc 222_222

  @impl true
  def handle_init(_ctx, opts) do
    {ip, port} = Keyword.fetch!(opts, :target)
    owner = Keyword.get(opts, :owner)
    output = Keyword.get(opts, :output, Beamicom.NES.Output)
    video = Keyword.get(opts, :video, %{width: 256, height: 240, frame_rate: 60.0988})
    audio = Keyword.get(opts, :audio, %{sample_rate: 44_100, channels: 1, sample_format: :s16le})
    pts_offset_ns = Keyword.get(opts, :pts_offset_ns, 0)
    period_ns = round(1_000_000_000 / video.frame_rate)

    spec = [
      child(:video_src, %VideoSource{
        owner: owner,
        output: output,
        width: video.width,
        height: video.height,
        period_ns: period_ns,
        pts_offset_ns: pts_offset_ns
      })
      |> child(:scaler, %Membrane.FFmpeg.SWScale.Converter{format: :I420})
      |> child(:av1, %Membrane.AV1.Encoder{
        real_time_coding: true,
        encoder_mode: 8,
        rate_control: {:crf, 20},
        approx_framerate: {round(video.frame_rate * 1_000), 1_000},
        config_parameters: %{"scm" => "2"}
      })
      |> child(:av1_pay, Av1Payloader)
      |> child(:video_rtp, %RtpSerializer{
        ssrc: @video_ssrc,
        payload_type: 96,
        clock_rate: 90_000
      })
      |> child(:udp_video, %UDP.Sink{destination_address: ip, destination_port_no: port}),
      child(:audio_src, %AudioSource{
        owner: owner,
        output: output,
        channels: audio.channels,
        sample_rate: audio.sample_rate,
        sample_format: audio.sample_format,
        pts_offset_ns: pts_offset_ns
      })
      |> child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          channels: audio.channels,
          sample_rate: 48_000,
          sample_format: :s16le
        }
      })
      |> child(:opus, Membrane.Opus.Encoder)
      |> child(:opus_pay, Membrane.RTP.Opus.Payloader)
      |> child(:audio_rtp, %RtpSerializer{
        ssrc: @audio_ssrc,
        payload_type: 111,
        clock_rate: 48_000
      })
      |> child(:udp_audio, %UDP.Sink{destination_address: ip, destination_port_no: port + 2})
    ]

    {[spec: spec], %{}}
  end
end
