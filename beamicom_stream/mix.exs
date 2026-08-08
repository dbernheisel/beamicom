defmodule BeamicomStream.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_stream,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {BeamicomStream.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:beamicom, path: "../beamicom"},
      {:membrane_core, "~> 1.3"},
      {:membrane_ffmpeg_swscale_plugin, "~> 0.16"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:membrane_opus_plugin, "~> 0.21"},
      {:membrane_udp_plugin, "~> 0.14.4"},
      {:membrane_av1_plugin, "~> 0.3.0"},
      {:membrane_rtp_opus_plugin, "~> 0.10"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:ex_webrtc, "~> 0.15"}
    ]
  end
end
