defmodule BeamicomPhxWeb.WatchLiveTest do
  use BeamicomPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The dead render (disconnected) path exercises the route and player markup
  # without starting the A/V pipeline or ex_webrtc stack, keeping the default
  # suite uncontaminated. The live_render wrapper for "videoPlayer" emits
  # id="videoPlayer-lv" in the dead render HTML, which is enough to confirm
  # the route exists and the player element is wired up.
  test "GET / renders the player element", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert [_ | _] = document |> LazyHTML.query("#videoPlayer-lv") |> LazyHTML.to_tree()

    assert [_ | _] =
             document
             |> LazyHTML.query(~s(input[type="file"][accept*=".gbc"]))
             |> LazyHTML.to_tree()

    assert [_ | _] =
             document
             |> LazyHTML.query(~s(#crt-canvas[data-video-width="256"][data-video-height="240"]))
             |> LazyHTML.to_tree()
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
    previous_saves_dir = Application.fetch_env!(:beamicom_phx, :saves_dir)

    saves_dir =
      Path.join(
        System.tmp_dir!(),
        "beamicom-live-saves-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(saves_dir)
    File.write!(Path.join(saves_dir, "broken.png"), "not a PNG")
    Application.put_env(:beamicom_phx, :saves_dir, saves_dir)

    on_exit(fn ->
      Application.put_env(:beamicom_phx, :saves_dir, previous_saves_dir)
      File.rm_rf!(saves_dir)
    end)

    assert :ok = BeamicomPhx.Emulator.stop()
    on_exit(&BeamicomPhx.Emulator.stop/0)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#load-broken")
    element(view, "#load-broken") |> render_click()
    assert has_element?(view, "#flash-error", "Couldn't load that save")
    assert has_element?(view, "#rom-upload")

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
    {:ok, view, _html} = live(recycle(conn), cgb_path)
    assert has_element?(view, "#rom-drop-label", "diagnostic.gbc")
    assert has_element?(view, ~s(.crt[data-system="gbc"]))

    assert has_element?(
             view,
             ~s(#crt-canvas[data-video-width="160"][data-video-height="144"])
           )

    assert has_element?(view, "#save-state:not([disabled])")
    element(view, "#save-state") |> render_click()
    save_url = Enum.find(BeamicomPhx.Saves.list(), &(&1 != "/saves/broken.png"))
    assert is_binary(save_url)
    assert has_element?(view, "#load-" <> Path.basename(save_url, ".png"))

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

    assert has_element?(
             view,
             "#rom-drop-label",
             "▸ diagnostic.gb — drop a .nes, .gb, or .gbc to change"
           )

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
    assert has_element?(view, "#flash-error", "Couldn't load broken.gbc")

    assert has_element?(
             view,
             "#rom-drop-label",
             "▸ diagnostic.gb — drop a .nes, .gb, or .gbc to change"
           )

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
    {:ok, view, _html} = live(recycle(conn), nes_path)
    assert has_element?(view, "#rom-drop-label", "basics.nes")
    assert has_element?(view, ~s(.crt[data-system="nes"]))

    assert has_element?(
             view,
             ~s(#crt-canvas[data-video-width="256"][data-video-height="240"])
           )
  end
end
