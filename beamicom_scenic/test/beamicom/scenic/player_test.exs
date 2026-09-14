defmodule Beamicom.Scenic.PlayerTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.Scenic.{Host, Player, SaveState, Shell, Shutdown}

  setup do
    original_viewport = Application.fetch_env!(:beamicom_scenic, :viewport)
    Application.put_env(:beamicom_scenic, :viewport, Keyword.put(original_viewport, :drivers, []))
    original_config_home = System.get_env("XDG_CONFIG_HOME")

    config_home =
      Path.join(
        System.tmp_dir!(),
        "beamicom-scenic-config-#{System.unique_integer([:positive])}"
      )

    System.put_env("XDG_CONFIG_HOME", config_home)

    path =
      Path.join(System.tmp_dir!(), "beamicom-scenic-#{System.unique_integer([:positive])}.gbc")

    File.write!(path, rom())

    on_exit(fn ->
      Beamicom.Scenic.stop()
      Application.put_env(:beamicom_scenic, :viewport, original_viewport)
      restore_env("XDG_CONFIG_HOME", original_config_home)
      File.rm(path)
      File.rm_rf(config_home)
    end)

    {:ok, path: path, original_viewport: original_viewport}
  end

  test "starts a long-lived shell without media" do
    assert :ok = Beamicom.Scenic.start()
    assert %{state: :idle, path: nil, error: nil} = Beamicom.Scenic.status()
    assert Process.whereis(Player) == nil

    host = Process.whereis(Host)
    host_state = :sys.get_state(host)
    scenic = host_state.scenic
    tasks = host_state.tasks
    assert is_pid(host)
    assert Process.alive?(scenic)
    assert Process.alive?(tasks)
    assert is_reference(host_state.viewport_ref)
    assert {:monitors, monitors} = Process.info(host, :monitors)
    assert {:process, host_state.viewport.pid} in monitors

    assert eventually(fn -> is_pid(:sys.get_state(host).shell) end)
    shell = :sys.get_state(host).shell

    [background] =
      shell
      |> :sys.get_state()
      |> Map.fetch!(:assigns)
      |> Map.fetch!(:graph)
      |> Scenic.Graph.get(:background)

    assert background.data |> elem(1) == {916, 756}
    assert background.styles.scissor == {916, 756}
    assert background.transforms.translate == {22, 22}

    {:ok, [background_pid]} = Scenic.Scene.child(:sys.get_state(shell), :background)
    started_at = :sys.get_state(background_pid).assigns.started_at

    assert {:noreply, pending_resize} =
             Shell.handle_input(
               {:viewport, {:reshape, {1_100, 900}}},
               nil,
               :sys.get_state(shell)
             )

    assert {:noreply, resized} =
             Shell.handle_info(
               {:apply_resize, pending_resize.assigns.resize_token},
               pending_resize
             )

    assert eventually(fn ->
             {:ok, [resized_background]} = Scenic.Scene.child(resized, :background)

             resized_background == background_pid and
               :sys.get_state(resized_background).assigns.size == {1_056, 856}
           end)

    assert :sys.get_state(background_pid).assigns.started_at == started_at

    assert :ok = Beamicom.Scenic.start()
    assert Process.whereis(Host) == host
    assert :sys.get_state(host).scenic == scenic
    assert :sys.get_state(host).tasks == tasks
  end

  test "the configured native driver accepts its close behavior", %{
    original_viewport: viewport
  } do
    [driver] = Keyword.fetch!(viewport, :drivers)
    {module, options} = Keyword.pop!(driver, :module)

    assert module == Scenic.Driver.Local
    assert {:ok, validated} = module.validate_opts(options)
    assert validated[:on_close] == :stop_viewport
  end

  test "rejects a repeat launch before creating children and owns shutdown", %{path: path} do
    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    assert %{system: :gbc, video: %{width: 160, height: 144}} = Beamicom.Scenic.status()

    player = Process.whereis(Player)
    state = :sys.get_state(player)
    children = child_pids(state)
    host_state = Host |> Process.whereis() |> :sys.get_state()
    all_children = [host_state.scenic, host_state.tasks | children]
    assert length(children) == 4
    assert Enum.all?(children, &Process.alive?/1)
    assert Process.alive?(host_state.scenic)
    assert :sys.get_state(state.input_server).ports == [1]
    assert :sys.get_state(state.input_client).ports == [1]
    assert Process.whereis(Beamicom.Scenic.EIServer) == state.input_server
    assert Process.whereis(Beamicom.Scenic.EIClient) == state.input_client

    assert :ok = Beamicom.EI.Client.set_buttons(state.input_client, 1, [:a])
    assert await_buttons(state.runtime, 0x10)
    assert {:error, :not_ready} = Beamicom.EI.Client.set_buttons(state.input_client, 2, [:a])

    links_before = links(player)

    assert_raise ArgumentError, "Beamicom Scenic is already running", fn ->
      Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    end

    assert Process.whereis(Player) == player
    assert links(player) == links_before
    assert child_pids(:sys.get_state(player)) == children

    monitors = Enum.map(all_children, &Process.monitor/1)
    assert :ok = Beamicom.Scenic.stop()
    assert Process.whereis(Player) == nil
    assert Process.whereis(Host) == nil

    for {child, monitor} <- Enum.zip(all_children, monitors) do
      assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 1_000
      refute Process.alive?(child)
    end

    assert {:error, :not_running} = Beamicom.Scenic.status()
  end

  test "legacy play facade routes NES and owns its lifecycle" do
    path =
      Path.join(System.tmp_dir!(), "beamicom-scenic-#{System.unique_integer([:positive])}.nes")

    File.write!(path, minimal_nes_rom())
    on_exit(fn -> File.rm(path) end)

    assert :ok =
             Beamicom.NES.Scenic.play(path,
               audio: false,
               speed: 0.01,
               video_filter: :native
             )

    assert %{
             system: :nes,
             video: %{width: 256, height: 240, scaled_width: 768, scaled_height: 720}
           } = Beamicom.Scenic.status()

    host = Process.whereis(Host)
    assert eventually(fn -> is_pid(:sys.get_state(host).shell) end)
    shell = :sys.get_state(host).shell

    assert eventually(fn -> not is_nil(:sys.get_state(shell).assigns.session) end)
    session = :sys.get_state(shell).assigns.session
    assert Keyword.fetch!(session.options, :output_size) == {768, 720}
    assert session.placements.running.scale == 1.0
    assert session.placements.running.output_size == {768, 720}
    assert session.placements.running.integer_scale == 3
    assert session.placements.hud == session.placements.running

    assert eventually(fn ->
             match?({:ok, [_surface]}, Scenic.Scene.child(:sys.get_state(shell), :game_surface))
           end)

    {:ok, [surface_before_resize]} = Scenic.Scene.child(:sys.get_state(shell), :game_surface)

    assert {:noreply, pending_resize} =
             Shell.handle_input(
               {:viewport, {:reshape, {1_024, 960}}},
               nil,
               :sys.get_state(shell)
             )

    assert pending_resize.assigns.pending_size == {1_024, 960}

    assert {:noreply, resized} =
             Shell.handle_info(
               {:apply_resize, pending_resize.assigns.resize_token},
               pending_resize
             )

    assert resized.assigns.session.placements.running.output_size == {1_024, 960}
    assert resized.assigns.session.placements.running.integer_scale == 4
    assert resized.assigns.session.placements.running.scale == 1.0

    assert eventually(fn ->
             {:ok, [surface]} = Scenic.Scene.child(resized, :game_surface)

             surface == surface_before_resize and
               :sys.get_state(surface).assigns.output_size == {1_024, 960}
           end)

    runtime = :sys.get_state(Player).runtime
    assert :ok = Host.set_enhancement(:unlimited_sprites, true)
    assert :ok = Host.set_enhancement(:hide_horizontal_overscan, true)

    assert :sys.get_state(runtime).pending_enhancements == [
             hide_horizontal_overscan: true,
             unlimited_sprites: true
           ]

    assert :sys.get_state(Host).session.options[:enhancements] == [
             hide_horizontal_overscan: true,
             unlimited_sprites: true
           ]

    native_player = Process.whereis(Player)
    assert :ok = Beamicom.Scenic.pause()
    assert :ok = Host.reconfigure(video_filter: :svideo)
    refute Process.whereis(Player) == native_player

    assert %{
             state: :menu_paused,
             paused: true,
             video_filter: :svideo,
             video: %{width: 602, height: 240}
           } = Beamicom.Scenic.status()

    filtered_runtime = :sys.get_state(Player).runtime
    filtered_ppu = :sys.get_state(filtered_runtime).console.bus.ppu
    assert filtered_ppu.unlimited_sprites
    assert filtered_ppu.hide_horizontal_overscan

    filtered_player = Process.whereis(Player)
    assert :ok = Host.reconfigure(video_filter: nil)
    refute Process.whereis(Player) == filtered_player

    assert %{
             state: :menu_paused,
             paused: true,
             video_filter: nil,
             video: %{width: 256, height: 240}
           } = Beamicom.Scenic.status()

    state = Player |> Process.whereis() |> :sys.get_state()
    assert Process.whereis(Beamicom.Scenic.EIServer) == state.input_server
    assert Process.whereis(Beamicom.Scenic.EIClient) == state.input_client
    assert :sys.get_state(state.runtime).audio_slices == 1
    assert :ok = Beamicom.Scenic.stop()
    assert eventually(fn -> is_nil(Process.whereis(Player)) end)

    assert :ok =
             Beamicom.NES.Scenic.play(path,
               audio: false,
               speed: 0.01,
               video_filter: :svideo
             )

    assert %{
             scale: 1,
             video_filter: :svideo,
             video: %{width: 602, height: 240, scaled_width: 602, scaled_height: 480}
           } = Beamicom.Scenic.status()
  end

  test "an initialization failure rolls back anonymous output and runtime children", %{path: path} do
    socket =
      Path.join(
        System.tmp_dir!(),
        "beamicom-scenic-conflict-#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> File.rm(socket) end)

    start_supervised!(
      {Beamicom.EI.Server,
       name: Beamicom.Scenic.EIServer, path: socket, ports: [1], on_buttons: fn _, _ -> :ok end}
    )

    outputs_before = processes_started_by(Beamicom.Host.Output)
    runtimes_before = processes_started_by(Beamicom.Host.Runtime)

    assert_raise ArgumentError, fn ->
      Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    end

    assert Process.whereis(Player) == nil
    assert eventually(fn -> processes_started_by(Beamicom.Host.Output) == outputs_before end)
    assert eventually(fn -> processes_started_by(Beamicom.Host.Runtime) == runtimes_before end)
  end

  test "an optional audio exit leaves the player and video runtime alive", %{path: path} do
    assert :ok =
             Beamicom.Scenic.play(path,
               audio_command: ["true"],
               speed: 0.01
             )

    player = Process.whereis(Player)
    assert is_pid(player)
    assert eventually(fn -> is_nil(:sys.get_state(player).audio) end)

    state = :sys.get_state(player)
    assert Process.alive?(state.runtime)
    assert Process.alive?(:sys.get_state(Host).scenic)
    assert %{system: :gbc, video: %{width: 160, height: 144}} = Beamicom.Scenic.status()
  end

  test "accepts the Game Boy Pixel Transparency presentation filter", %{path: path} do
    assert :ok =
             Beamicom.Scenic.play(path,
               audio: false,
               speed: 0.01,
               video_filter: :pixel_transparency,
               video_filter_options: [base_alpha: 0.3],
               scale: 2
             )

    assert %{
             system: :gbc,
             video_filter: :pixel_transparency,
             video: %{scaled_width: 320, scaled_height: 288}
           } = Beamicom.Scenic.status()

    assert :sys.get_state(Player).video_filter == {:pixel_transparency, [base_alpha: 0.3]}
  end

  test "reconfigures the active video pipeline and restores its paused mode", %{path: path} do
    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    assert :ok = Beamicom.Scenic.pause()

    first_player = Process.whereis(Player)
    first_status = Beamicom.Scenic.status()

    assert :ok = Host.reconfigure(video_filter: :pixel_transparency)

    second_player = Process.whereis(Player)
    refute second_player == first_player
    assert eventually(fn -> not Process.alive?(first_player) end)

    assert %{
             state: :menu_paused,
             paused: true,
             path: path,
             rom_hash: rom_hash,
             video_filter: :pixel_transparency
           } = Beamicom.Scenic.status()

    assert path == first_status.path
    assert rom_hash == first_status.rom_hash
    assert :sys.get_state(second_player).paused
  end

  test "pauses, resumes, replaces, resets, and unloads a session without replacing Scenic", %{
    path: path
  } do
    assert :ok = Beamicom.Scenic.replace(path, audio: false, speed: 0.01)

    host = Process.whereis(Host)
    assert eventually(fn -> is_pid(:sys.get_state(host).shell) end)
    scenic = :sys.get_state(host).scenic
    shell = :sys.get_state(host).shell
    first_player = Process.whereis(Player)
    first_runtime = :sys.get_state(first_player).runtime

    assert eventually(fn ->
             graph = :sys.get_state(shell).assigns.graph

             Scenic.Graph.get(graph, :game_surface) != [] and
               Scenic.Graph.get(graph, :menu_bar) == [] and
               Scenic.Graph.get(graph, :status_bar) == [] and
               Scenic.Graph.get(graph, :background) == []
           end)

    assert {:noreply, _scene} =
             Shell.handle_input(
               {:key, {:key_esc, 1, []}},
               nil,
               :sys.get_state(shell)
             )

    assert %{state: :menu_paused, paused: true} = Beamicom.Scenic.status()
    assert eventually(fn -> :sys.get_state(first_runtime).paused end)
    assert eventually(fn -> :sys.get_state(shell).assigns.mode == :menu_paused end)

    assert eventually(fn ->
             graph = :sys.get_state(shell).assigns.graph

             Scenic.Graph.get(graph, :game_surface) != [] and
               Scenic.Graph.get(graph, :menu_bar) != [] and
               Scenic.Graph.get(graph, :status_bar) != [] and
               Scenic.Graph.get(graph, :background) == []
           end)

    first_state = :sys.get_state(first_player)
    assert :ok = Beamicom.EI.Client.set_buttons(first_state.input_client, 1, [:down])

    assert eventually(fn ->
             shell_state = :sys.get_state(shell)
             {:ok, [menu]} = Scenic.Scene.child(shell_state, :menu_bar)
             :sys.get_state(menu).assigns.menu_state.selected_item == 1
           end)

    shell_state = :sys.get_state(shell)
    {:ok, [menu]} = Scenic.Scene.child(shell_state, :menu_bar)
    :ok = Scenic.Scene.put_child(shell_state, :menu_bar, {:key, :key_right})
    :ok = Scenic.Scene.put_child(shell_state, :menu_bar, {:key, :key_down})
    :ok = Scenic.Scene.put_child(shell_state, :menu_bar, {:key, :key_right})

    assert eventually(fn ->
             menu_state = :sys.get_state(menu)

             menu_state.assigns.menu_state.open_menu == 1 and
               menu_state.assigns.menu_state.open_submenu == 2 and
               menu_state.assigns.menu_state.selected_subitem == 1 and
               Scenic.Graph.get(menu_state.assigns.graph, {:submenu_item, 1}) != []
           end)

    assert {:noreply, _scene} =
             Shell.handle_input(
               {:key, {:key_esc, 1, []}},
               nil,
               :sys.get_state(shell)
             )

    assert %{state: :running, paused: false} = Beamicom.Scenic.status()
    assert eventually(fn -> not :sys.get_state(first_runtime).paused end)

    assert eventually(fn ->
             graph = :sys.get_state(shell).assigns.graph

             Scenic.Graph.get(graph, :game_surface) != [] and
               Scenic.Graph.get(graph, :menu_bar) == [] and
               Scenic.Graph.get(graph, :status_bar) == [] and
               Scenic.Graph.get(graph, :background) == []
           end)

    missing = path <> ".missing"
    assert {:error, :enoent} = Beamicom.Scenic.replace(missing, audio: false)
    assert Process.whereis(Player) == first_player
    assert Process.alive?(first_runtime)

    assert :ok = Beamicom.Scenic.replace(path, audio: false, speed: 0.02)
    second_player = Process.whereis(Player)
    second_children = child_pids(:sys.get_state(second_player))
    refute second_player == first_player
    assert eventually(fn -> not Process.alive?(first_player) end)
    assert eventually(fn -> not Process.alive?(first_runtime) end)
    assert :sys.get_state(host).scenic == scenic
    assert :sys.get_state(host).shell == shell
    assert Process.alive?(shell)
    assert %{state: :running, speed: 0.02} = Beamicom.Scenic.status()

    assert :ok = Beamicom.Scenic.reset()
    third_player = Process.whereis(Player)
    refute third_player == second_player
    assert eventually(fn -> not Process.alive?(second_player) end)

    assert Enum.all?(second_children, fn child ->
             eventually(fn -> not Process.alive?(child) end)
           end)

    assert :sys.get_state(host).scenic == scenic
    assert :sys.get_state(host).shell == shell
    assert Process.alive?(shell)

    assert :ok = Beamicom.Scenic.unload()
    assert eventually(fn -> not Process.alive?(third_player) end)
    assert %{state: :idle, path: nil, error: nil} = Beamicom.Scenic.status()
    assert Process.alive?(scenic)
    assert Process.alive?(shell)
    assert {:error, :no_session} = Beamicom.Scenic.pause()
    assert {:error, :no_session} = Beamicom.Scenic.resume()
    assert {:error, :no_session} = Beamicom.Scenic.reset()
  end

  test "snapshots and reloads a Game Boy session as a self-identifying PNG", %{path: path} do
    save_path =
      Path.join(System.tmp_dir!(), "beamicom-scenic-#{System.unique_integer([:positive])}.png")

    on_exit(fn -> File.rm(save_path) end)

    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    assert {:ok, snapshot} = await_snapshot()
    assert :ok = SaveState.write(snapshot, save_path)
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = File.read!(save_path)

    assert :ok = Beamicom.Scenic.replace(save_path, audio: false, speed: 0.01)
    assert %{state: :running, system: :gbc, path: ^save_path} = Beamicom.Scenic.status()
  end

  test "F5 and F8 quick-save and quick-load the ROM hash slot", %{path: path} do
    state_dir =
      Path.join(
        System.tmp_dir!(),
        "beamicom-scenic-states-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(state_dir) end)

    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    host = Process.whereis(Host)
    assert eventually(fn -> is_pid(:sys.get_state(host).shell) end)
    shell = :sys.get_state(host).shell
    assert eventually(fn -> not is_nil(:sys.get_state(shell).assigns.session) end)
    assert {:ok, _snapshot} = await_snapshot()

    rom_hash = :crypto.hash(:sha256, rom()) |> Base.encode16(case: :lower)
    quick_path = SaveState.quick_path(state_dir, rom_hash)

    scene = :sys.get_state(shell)
    scene = put_in(scene.assigns.settings.save_state_folder, state_dir)

    assert {:noreply, saving_scene} =
             Shell.handle_input({:key, {:key_f5, 1, []}}, nil, scene)

    assert is_pid(saving_scene.assigns.load_ref)
    assert_receive {:save_result, :ok, ^quick_path} = saved, 5_000
    assert File.regular?(quick_path)
    assert {:noreply, _saved_scene} = Shell.handle_info(saved, saving_scene)

    assert :ok = Beamicom.Scenic.pause()
    assert eventually(fn -> :sys.get_state(shell).assigns.mode == :menu_paused end)
    browser_source = :sys.get_state(shell)
    browser_source = put_in(browser_source.assigns.settings.save_state_folder, state_dir)

    assert {:noreply, browser_scene} =
             Shell.handle_event({:menu_action, :load_state}, nil, browser_source)

    assert browser_scene.assigns.mode == :state_browser
    assert browser_scene.assigns.state_browser.paths == [quick_path]
    assert Scenic.Graph.get(browser_scene.assigns.graph, :state_browser) != []

    assert eventually(fn ->
             match?({:ok, [_browser]}, Scenic.Scene.child(browser_scene, :state_browser))
           end)

    {:ok, [browser]} = Scenic.Scene.child(browser_scene, :state_browser)
    assert length(:sys.get_state(browser).assigns.entries) == 1

    assert {:noreply, saved_scene} =
             Shell.handle_event({:state_browser, :cancel}, nil, browser_scene)

    assert saved_scene.assigns.mode == :menu_paused
    assert saved_scene.assigns.state_browser == nil

    assert {:noreply, loading_scene} =
             Shell.handle_input({:key, {:key_f8, 1, []}}, nil, saved_scene)

    assert loading_scene.assigns.mode == :loading
    assert_receive {:load_result, :ok, ^quick_path}, 5_000

    assert eventually(fn ->
             match?(
               %{path: ^quick_path, rom_hash: ^rom_hash, state: :running},
               Beamicom.Scenic.status()
             )
           end)
  end

  test "repeated load, reset, and quit cycles leave no session processes", %{path: path} do
    outputs_before = processes_started_by(Beamicom.Host.Output)
    runtimes_before = processes_started_by(Beamicom.Host.Runtime)

    for _cycle <- 1..3 do
      assert :ok = Beamicom.Scenic.replace(path, audio: false, speed: 0.01)
      assert eventually(fn -> is_pid(:sys.get_state(Host).shell) end)
      assert :ok = Beamicom.Scenic.reset()

      player = Process.whereis(Player)
      children = child_pids(:sys.get_state(player))
      monitors = Enum.map([player | children], &{&1, Process.monitor(&1)})

      assert :ok = Beamicom.Scenic.stop()
      assert Process.whereis(Host) == nil
      assert Process.whereis(Player) == nil

      for {process, monitor} <- monitors do
        assert_receive {:DOWN, ^monitor, :process, ^process, _reason}, 1_000
      end

      assert eventually(fn -> processes_started_by(Beamicom.Host.Output) == outputs_before end)
      assert eventually(fn -> processes_started_by(Beamicom.Host.Runtime) == runtimes_before end)
    end
  end

  test "window shutdown stops emulation before requesting system shutdown", %{path: path} do
    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    player = Process.whereis(Player)
    children = child_pids(:sys.get_state(player))
    owner = self()

    assert :ok =
             Shutdown.run(17, fn status ->
               send(
                 owner,
                 {:system_stop, status, Process.whereis(Host), Process.whereis(Player),
                  Enum.any?(children, &Process.alive?/1)}
               )

               :ok
             end)

    assert_receive {:system_stop, 17, nil, nil, false}
  end

  defp child_pids(state) do
    [
      state.owned_output,
      state.audio,
      state.runtime,
      state.input_server,
      state.input_client
    ]
    |> Enum.filter(&is_pid/1)
  end

  defp links(pid) do
    {:links, links} = Process.info(pid, :links)
    Enum.sort(links)
  end

  defp await_buttons(runtime, expected, attempts \\ 100)
  defp await_buttons(_runtime, _expected, 0), do: false

  defp await_buttons(runtime, expected, attempts) do
    if :sys.get_state(runtime).machine.bus.buttons == expected do
      true
    else
      Process.sleep(5)
      await_buttons(runtime, expected, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp await_snapshot(attempts \\ 100)
  defp await_snapshot(0), do: {:error, :no_frame}

  defp await_snapshot(attempts) do
    case Host.snapshot() do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :no_frame} ->
        Process.sleep(5)
        await_snapshot(attempts - 1)
    end
  end

  defp processes_started_by(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        match?({^module, _function, _arity}, :proc_lib.translate_initial_call(pid))
      catch
        :exit, _reason -> false
      end
    end)
    |> MapSet.new()
  end

  defp rom do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0xC3, 0x50, 0x01>>)
    |> put_bytes(0x134, "SCENIC OWNER" <> :binary.copy(<<0>>, 4))
    |> put_byte(0x143, 0x80)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> put_bytes(0x150, <<0x18, 0xFE>>)
    |> with_checksum()
  end

  defp minimal_nes_rom do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, 1, 0::size(10 * 8)>> <> prg <> <<0::size(8192 * 8)>>
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end

  defp restore_env(variable, nil), do: System.delete_env(variable)
  defp restore_env(variable, value), do: System.put_env(variable, value)
end
