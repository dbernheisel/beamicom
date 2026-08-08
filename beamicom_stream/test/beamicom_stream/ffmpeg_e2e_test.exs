defmodule BeamicomStream.FFmpegE2ETest do
  use ExUnit.Case, async: false
  @moduletag :ffmpeg_e2e

  alias BeamicomStream.SDP

  test "a real ROM produces decodable AV1 video and Opus audio" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is not available")
    base_port = 20_000 + rem(System.unique_integer([:positive]), 20_000)
    {:ok, sdp} = SDP.write_temp({127, 0, 0, 1}, base_port)
    rom = Path.expand("../../../beamicom_phx/test/support/fixtures/01.basics.nes", __DIR__)

    receiver =
      Task.async(fn ->
        System.cmd(
          ffmpeg,
          [
            "-hide_banner",
            "-loglevel",
            "info",
            "-protocol_whitelist",
            "file,udp,rtp",
            "-i",
            sdp,
            "-t",
            "1",
            "-map",
            "0:v:0",
            "-map",
            "0:a:0",
            "-f",
            "null",
            "-"
          ],
          stderr_to_stdout: true
        )
      end)

    {:ok, player} =
      BeamicomStream.play(rom,
        target: {{127, 0, 0, 1}, base_port},
        runtime_name: :beamicom_stream_e2e_runtime
      )

    try do
      assert {output, 0} = Task.await(receiver, 20_000)
      assert output =~ "Video: av1"
      assert output =~ "Audio: opus"
      assert output =~ "video:"
      assert output =~ "audio:"
    after
      if Process.alive?(player), do: BeamicomStream.stop(player)
      File.rm(sdp)
    end
  end
end
