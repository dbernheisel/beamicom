defmodule BeamicomPhx.RtpConfig do
  @moduledoc """
  Reads the relay's UDP endpoints from the environment.

  - `BEAMICOM_RTP_TARGET` ("host:port") — where the SERVER sends its RTP broadcast
    (the client node). Video goes to `port`, audio to `port + 2`.
  - `BEAMICOM_RTP_LISTEN` (integer, default 5000) — the CLIENT's base receive port
    (video on base, audio on base + 2).
  """

  @doc "The server's broadcast target as `{ip_tuple, port}`, or nil when unset."
  def target, do: Application.get_env(:beamicom_phx, :rtp_target)

  @doc "The client's base UDP receive port."
  def listen_port, do: Application.get_env(:beamicom_phx, :rtp_listen)
end
