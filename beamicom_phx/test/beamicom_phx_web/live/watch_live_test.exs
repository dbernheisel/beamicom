defmodule BeamicomPhxWeb.WatchLiveTest do
  use BeamicomPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The dead render (disconnected) path exercises the route and player markup
  # without starting the A/V pipeline or ex_webrtc stack, keeping the default
  # suite uncontaminated. The live_render wrapper for "videoPlayer" emits
  # id="videoPlayer-lv" in the dead render HTML, which is enough to confirm
  # the route exists and the player element is wired up.
  test "GET / renders the player element", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "videoPlayer"
    assert html_response(conn, 200) =~ ".gbc"
    assert html_response(conn, 200) =~ ~s(data-video-width="256")
    assert html_response(conn, 200) =~ ~s(data-video-height="240")
  end

  test "CRT hook follows decoded relay dimensions" do
    source = File.read!("assets/js/crt.js")
    assert source =~ "video.videoWidth"
    assert source =~ "video.videoHeight"
    assert source =~ "this.setSourceGeometry(video.videoWidth, video.videoHeight)"
    assert source =~ ~s(crt.dataset.system = width === 256 && height === 240 ? "nes" : "gbc")
  end

  @tag :integration
  test "uploads CGB and NES ROMs and rebuilds the browser pipeline", %{conn: conn} do
    assert :ok = BeamicomPhx.Emulator.stop()
    on_exit(&BeamicomPhx.Emulator.stop/0)
    {:ok, view, _html} = live(conn, ~p"/")

    cgb =
      file_input(view, "#rom-upload", :rom, [
        %{
          name: "diagnostic.gbc",
          content: Beamicom.GB.DiagnosticROM.build_cgb(),
          type: "application/x-gameboy-color-rom"
        }
      ])

    assert {:error, {:redirect, %{to: cgb_path}}} = render_upload(cgb, "diagnostic.gbc")
    assert BeamicomPhx.Emulator.system() == :gbc
    assert cgb_path =~ "stream_epoch="
    {:ok, view, html} = live(recycle(conn), cgb_path)
    assert html =~ "diagnostic.gbc"
    assert html =~ ~s(data-system="gbc")
    assert html =~ ~s(data-video-width="160")
    assert html =~ ~s(data-video-height="144")

    assert render_click(view, "save_state", %{}) =~
             "Game Boy save states are not supported yet"

    dmg =
      file_input(view, "#rom-upload", :rom, [
        %{
          name: "diagnostic.gb",
          content: Beamicom.GB.DiagnosticROM.build(),
          type: "application/x-gameboy-rom"
        }
      ])

    render_upload(dmg, "diagnostic.gb")
    assert BeamicomPhx.Emulator.system() == :gbc
    assert Process.alive?(view.pid)
    assert render(view) =~ "diagnostic.gb"

    profile_before_bad_upload = BeamicomPhx.Emulator.profile()
    children_before_bad_upload = DynamicSupervisor.which_children(BeamicomPhx.RuntimeSupervisor)

    malformed =
      file_input(view, "#rom-upload", :rom, [
        %{
          name: "broken.gbc",
          content: "bad",
          type: "application/x-gameboy-color-rom"
        }
      ])

    render_upload(malformed, "broken.gbc")
    assert Process.alive?(view.pid)
    refute render(view) =~ "broken.gbc"
    assert BeamicomPhx.Emulator.profile() == profile_before_bad_upload

    assert DynamicSupervisor.which_children(BeamicomPhx.RuntimeSupervisor) ==
             children_before_bad_upload

    nes =
      file_input(view, "#rom-upload", :rom, [
        %{
          name: "basics.nes",
          content: File.read!("test/support/fixtures/01.basics.nes"),
          type: "application/x-nes-rom"
        }
      ])

    assert {:error, {:redirect, %{to: nes_path}}} = render_upload(nes, "basics.nes")
    assert BeamicomPhx.Emulator.system() == :nes
    assert nes_path =~ "stream_epoch="
    {:ok, _view, html} = live(recycle(conn), nes_path)
    assert html =~ "basics.nes"
    assert html =~ ~s(data-system="nes")
    assert html =~ ~s(data-video-width="256")
    assert html =~ ~s(data-video-height="240")
  end
end
