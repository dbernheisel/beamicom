defmodule BeamicomStream.SDP do
  @moduledoc "Generates the SDP session used by ffplay to receive local AV1 and Opus RTP."

  @spec render(:inet.ip_address(), :inet.port_number(), 1 | 2) :: String.t()
  def render(host, port, channels \\ 1)

  def render({a, b, c, d} = host, port, channels)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
             port in 1..65_533 and channels in [1, 2] do
    address = host |> :inet.ntoa() |> to_string()

    """
    v=0
    o=- 0 0 IN IP4 #{address}
    s=Beamicom local AV1/Opus stream
    c=IN IP4 #{address}
    t=0 0
    m=video #{port} RTP/AVP 96
    a=rtpmap:96 AV1/90000
    a=recvonly
    m=audio #{port + 2} RTP/AVP 111
    a=rtpmap:111 opus/48000/#{channels}
    a=recvonly
    """
  end

  def write_temp(host, port, channels \\ 1) do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-stream-#{System.unique_integer([:positive, :monotonic])}.sdp"
      )

    case File.write(path, render(host, port, channels)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_sdp, reason}}
    end
  end
end
