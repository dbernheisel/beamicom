defmodule BeamicomPhxWeb.WatchLiveTest do
  use BeamicomPhxWeb.ConnCase, async: false

  # The dead render (disconnected) path exercises the route and player markup
  # without starting the A/V pipeline or ex_webrtc stack, keeping the default
  # suite uncontaminated. The live_render wrapper for "videoPlayer" emits
  # id="videoPlayer-lv" in the dead render HTML, which is enough to confirm
  # the route exists and the player element is wired up.
  test "GET / renders the player element", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "videoPlayer"
  end
end
