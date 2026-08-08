defmodule BeamicomStream.SDPTest do
  use ExUnit.Case, async: true

  alias BeamicomStream.SDP

  test "describes AV1 video and Opus audio on neighboring RTP port pairs" do
    sdp = SDP.render({127, 0, 0, 1}, 5_000)

    assert sdp =~ "c=IN IP4 127.0.0.1"
    assert sdp =~ "m=video 5000 RTP/AVP 96"
    assert sdp =~ "a=rtpmap:96 AV1/90000"
    assert sdp =~ "m=audio 5002 RTP/AVP 111"
    assert sdp =~ "a=rtpmap:111 opus/48000/1"
  end

  test "writes and removes a unique temporary file" do
    assert {:ok, path} = SDP.write_temp({127, 0, 0, 1}, 5_100)
    on_exit(fn -> File.rm(path) end)
    assert File.read!(path) == SDP.render({127, 0, 0, 1}, 5_100)
  end
end
