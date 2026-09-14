defmodule Beamicom.Scenic.Shell do
  @moduledoc "Long-lived root scene displayed when no emulator session is active."

  use Scenic.Scene

  import Scenic.Primitives, only: [rect: 2, rect: 3, text: 3]

  alias Beamicom.Scenic.Component.{
    Backdrop,
    Background,
    GameSurface,
    MenuBar,
    SaveStateBrowser,
    StatusBar
  }

  alias Beamicom.Scenic.{FileDialog, Layout, Menu, SaveState, Settings, Theme}
  alias Scenic.{Graph, Primitive}

  @media_filters [
    {"Beamicom media", ["nes", "gb", "gbc", "sfc", "smc", "png"]},
    {"NES ROMs", ["nes"]},
    {"Game Boy ROMs", ["gb", "gbc"]},
    {"SNES ROMs", ["sfc", "smc"]},
    {"Beamicom saves", ["png"]}
  ]
  @save_filters [{"Beamicom save image", ["png"]}]

  @impl true
  def init(scene, _params, _opts) do
    {width, height} = scene.viewport.size
    {settings, message} = load_settings()
    graph = build_graph(width, height, nil, message, :idle, settings)
    send(Beamicom.Scenic.Host, {:register_shell, self()})
    request_input(scene, [:key, :viewport])

    {:ok,
     scene
     |> assign(
       width: width,
       height: height,
       graph: graph,
       mode: :idle,
       session: nil,
       return_mode: nil,
       dialog_ref: nil,
       dialog_kind: nil,
       pending_snapshot: nil,
       state_browser: nil,
       load_ref: nil,
       resize_timer: nil,
       resize_token: nil,
       pending_size: nil,
       initial_directory: File.cwd!(),
       message: message,
       settings: settings
     )
     |> push_graph(graph)}
  end

  @impl Scenic.Scene
  def handle_input({:viewport, {:reshape, {width, height}}}, _id, scene)
      when width > 0 and height > 0 do
    {:noreply, schedule_resize(scene, width, height)}
  end

  def handle_input({:key, {key, action, _mods}}, _id, scene) when action in [0, 1] do
    key = normalize_key(key)
    down? = action == 1

    case {scene.assigns.mode, key, down?} do
      {:running, :key_escape, true} ->
        :ok = Beamicom.Scenic.Host.pause()
        {:noreply, scene}

      {:menu_paused, :key_escape, true} ->
        :ok = Beamicom.Scenic.Host.resume()
        {:noreply, scene}

      {mode, :key_f5, true} when mode in [:running, :menu_paused] ->
        {:noreply, quick_save(scene)}

      {mode, :key_f8, true} when mode in [:running, :menu_paused] ->
        {:noreply, quick_load(scene)}

      {mode, key, false}
      when mode in [:running, :menu_paused] and key in [:key_f5, :key_f8] ->
        {:noreply, scene}

      {:state_browser, _key, true} ->
        :ok = put_child(scene, :state_browser, {:key, key})
        {:noreply, scene}

      {:state_browser, _key, false} ->
        {:noreply, scene}

      {:running, _key, _down?} ->
        :ok = put_child(scene, :game_surface, {:key, key, down?})
        {:noreply, scene}

      {:loading, _key, _down?} ->
        {:noreply, scene}

      {_mode, _key, true} ->
        :ok = put_child(scene, :menu_bar, {:key, key})
        {:noreply, scene}

      _ ->
        {:noreply, scene}
    end
  end

  def handle_input(_input, _id, scene), do: {:noreply, scene}

  @impl Scenic.Scene
  def handle_event({:menu_action, :load}, _from, scene) do
    {:noreply, start_open_dialog(scene, :load, @media_filters, "selecting media...")}
  end

  def handle_event({:menu_action, :load_state}, _from, scene) do
    {:noreply, open_state_browser(scene)}
  end

  def handle_event({:state_browser, :load, path}, _from, scene) do
    {:noreply, scene |> close_state_browser() |> enter_loading() |> start_load(path)}
  end

  def handle_event({:state_browser, :open}, _from, scene) do
    {:noreply, start_open_dialog(scene, :load_state, @save_filters, "selecting state...")}
  end

  def handle_event({:state_browser, :cancel}, _from, scene) do
    {:noreply, close_state_browser(scene)}
  end

  def handle_event({:menu_action, :save_state}, _from, scene) do
    case Beamicom.Scenic.Host.snapshot() do
      {:ok, snapshot} ->
        {:noreply, start_save_dialog(scene, snapshot)}

      {:error, reason} ->
        {:noreply, put_message(scene, "snapshot failed: #{inspect(reason)}")}
    end
  end

  def handle_event({:menu_action, :save_state_folder}, _from, scene) do
    {:noreply, start_directory_dialog(scene)}
  end

  def handle_event({:menu_action, {:nes_video_filter, value}}, _from, scene)
      when value in [:none, :composite, :svideo, :rgb] do
    {:noreply, set_video_filter(scene, :nes, :nes_video_filter, value, "NES filter")}
  end

  def handle_event({:menu_action, {:gbc_video_filter, value}}, _from, scene)
      when value in [:none, :pixel_transparency] do
    {:noreply, set_video_filter(scene, :gbc, :gbc_video_filter, value, "GBC filter")}
  end

  def handle_event({:menu_action, :nes_remove_sprite_limit}, _from, scene) do
    {:noreply,
     set_nes_enhancement(
       scene,
       :nes_remove_sprite_limit,
       :unlimited_sprites,
       "remove sprite limit"
     )}
  end

  def handle_event({:menu_action, :nes_lighting}, _from, scene) do
    {:noreply, set_nes_lighting(scene)}
  end

  def handle_event({:menu_action, :nes_trim_borders}, _from, scene) do
    {:noreply,
     set_nes_enhancement(
       scene,
       :nes_trim_borders,
       :hide_horizontal_overscan,
       "trim borders"
     )}
  end

  def handle_event({:menu_action, :integer_scaling}, _from, scene) do
    value = not scene.assigns.settings.integer_scaling
    scene = save_setting(scene, :integer_scaling, value, "integer scaling")
    {:noreply, relayout(scene)}
  end

  def handle_event({:menu_action, :audio}, _from, scene) do
    value = not scene.assigns.settings.audio
    {:noreply, save_setting(scene, :audio, value, "audio")}
  end

  def handle_event({:menu_opened, _menu}, _from, %{assigns: %{mode: :running}} = scene) do
    :ok = Beamicom.Scenic.Host.pause()
    {:noreply, scene}
  end

  def handle_event({:menu_opened, _menu}, _from, scene), do: {:noreply, scene}

  def handle_event({:render_fps, fps}, _from, %{assigns: %{session: session}} = scene)
      when not is_nil(session) do
    session = put_in(session.status[:fps], fps)
    scene = assign(scene, session: session)

    if scene.assigns.mode == :running do
      {:noreply, scene}
    else
      {:noreply,
       update_child(
         scene,
         :status_bar,
         status_data(scene.assigns.width, session, scene.assigns.message)
       )}
    end
  end

  def handle_event({:render_fps, _fps}, _from, scene), do: {:noreply, scene}

  def handle_event({:menu_action, :run}, _from, scene) do
    case Beamicom.Scenic.Host.resume() do
      :ok -> {:noreply, scene}
      {:error, reason} -> {:noreply, put_message(scene, "run failed: #{inspect(reason)}")}
    end
  end

  def handle_event({:menu_action, :reset}, _from, scene) do
    owner = self()

    {:ok, task} =
      Task.Supervisor.start_child(Beamicom.Scenic.TaskSupervisor, fn ->
        send(owner, {:reset_result, Beamicom.Scenic.Host.reset()})
      end)

    {:noreply, scene |> enter_loading() |> assign(load_ref: task) |> put_message("resetting...")}
  end

  def handle_event({:menu_action, action}, _from, scene) do
    {:noreply, put_message(scene, "#{menu_label(action)} is not available yet")}
  end

  @impl true
  def handle_info({ref, result}, %{assigns: %{dialog_ref: ref}} = scene) do
    Process.demonitor(ref, [:flush])
    kind = scene.assigns.dialog_kind

    scene =
      assign(scene,
        dialog_ref: nil,
        dialog_kind: nil
      )

    case result do
      {:ok, path} when kind in [:load, :load_state] ->
        {:noreply, start_load(scene, path)}

      {:ok, path} when kind == :save_state ->
        {:noreply, start_save(scene, path)}

      {:ok, path} when kind == :save_state_folder ->
        {:noreply,
         scene
         |> restore_mode()
         |> save_setting(:save_state_folder, path, "save-state folder")}

      :cancel ->
        {:noreply,
         scene
         |> assign(pending_snapshot: nil)
         |> restore_mode()
         |> put_message("#{dialog_label(kind)} cancelled")}

      {:error, reason} ->
        {:noreply,
         scene
         |> assign(pending_snapshot: nil)
         |> restore_mode()
         |> put_message("file selector error: #{inspect(reason)}")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{dialog_ref: ref}} = scene) do
    {:noreply,
     scene
     |> assign(dialog_ref: nil, dialog_kind: nil, pending_snapshot: nil)
     |> restore_mode()
     |> put_message("file selector exited: #{inspect(reason)}")}
  end

  def handle_info({:load_result, :ok, _path}, scene), do: {:noreply, scene}

  def handle_info({:load_result, {:error, reason}, _path}, scene) do
    {:noreply,
     scene
     |> assign(load_ref: nil)
     |> restore_mode()
     |> put_message("load failed: #{inspect(reason)}")}
  end

  def handle_info({:reset_result, :ok}, scene), do: {:noreply, assign(scene, load_ref: nil)}

  def handle_info({:reset_result, {:error, reason}}, scene) do
    {:noreply,
     scene
     |> assign(load_ref: nil)
     |> restore_mode()
     |> put_message("reset failed: #{inspect(reason)}")}
  end

  def handle_info(
        {:apply_resize, token},
        %{assigns: %{resize_token: token, pending_size: {width, height}}} = scene
      ) do
    {:noreply,
     scene
     |> assign(resize_timer: nil, resize_token: nil, pending_size: nil)
     |> resize(width, height)}
  end

  def handle_info({:apply_resize, _stale_token}, scene), do: {:noreply, scene}

  def handle_info({:reconfigure_result, :ok}, scene),
    do: {:noreply, assign(scene, load_ref: nil)}

  def handle_info({:reconfigure_result, {:error, reason}}, scene) do
    {:noreply,
     scene
     |> assign(load_ref: nil)
     |> restore_mode()
     |> put_message("setting could not be applied: #{inspect(reason)}")}
  end

  def handle_info({:save_result, :ok, path}, scene) do
    {:noreply,
     scene
     |> assign(load_ref: nil, pending_snapshot: nil, initial_directory: Path.dirname(path))
     |> restore_mode()
     |> put_message("saved #{Path.basename(path)}")}
  end

  def handle_info({:save_result, {:error, reason}, _path}, scene) do
    {:noreply,
     scene
     |> assign(load_ref: nil, pending_snapshot: nil)
     |> restore_mode()
     |> put_message("save failed: #{inspect(reason)}")}
  end

  def handle_info({:session_started, scene_options, status}, scene),
    do: handle_info({:session_started, scene_options, status, :running}, scene)

  def handle_info({:session_started, scene_options, status, mode}, scene)
      when mode in [:running, :menu_paused] do
    session =
      fit_session(
        scene_options,
        status,
        scene.assigns.width,
        scene.assigns.height,
        scene.assigns.settings.integer_scaling
      )

    graph =
      build_graph(
        scene.assigns.width,
        scene.assigns.height,
        session,
        nil,
        mode,
        scene.assigns.settings
      )

    scene =
      scene
      |> assign(
        graph: graph,
        session: session,
        mode: mode,
        state_browser: nil,
        return_mode: nil,
        message: nil,
        load_ref: nil
      )
      |> push_graph(graph)

    {:noreply, scene}
  end

  def handle_info({:session_stopped, reason}, scene) do
    message = if reason, do: "session stopped: #{inspect(reason)}"

    graph =
      build_graph(
        scene.assigns.width,
        scene.assigns.height,
        nil,
        message,
        :idle,
        scene.assigns.settings
      )

    {:noreply,
     scene
     |> assign(
       graph: graph,
       session: nil,
       mode: :idle,
       state_browser: nil,
       return_mode: nil,
       message: message,
       load_ref: nil
     )
     |> push_graph(graph)}
  end

  def handle_info({:session_mode, mode}, scene) when mode in [:running, :menu_paused] do
    session = clear_fps(scene.assigns.session)

    graph =
      build_graph(
        scene.assigns.width,
        scene.assigns.height,
        session,
        nil,
        mode,
        scene.assigns.settings
      )

    scene =
      scene
      |> assign(graph: graph, mode: mode, session: session, message: nil)
      |> push_graph(graph)

    :ok = put_child(scene, :game_surface, :reset_fps)

    if mode == :menu_paused do
      :ok = put_child(scene, :menu_bar, {:open, :game})
    end

    {:noreply, scene}
  end

  def handle_info({:controller_menu, button}, %{assigns: %{mode: :menu_paused}} = scene) do
    case controller_key(button) do
      :resume ->
        :ok = Beamicom.Scenic.Host.resume()

      nil ->
        :ok

      key ->
        :ok = put_child(scene, :menu_bar, {:key, key})
    end

    {:noreply, scene}
  end

  def handle_info({:controller_menu, button}, %{assigns: %{mode: :state_browser}} = scene) do
    case state_browser_controller_key(button) do
      nil -> :ok
      key -> :ok = put_child(scene, :state_browser, {:key, key})
    end

    {:noreply, scene}
  end

  def handle_info({:controller_menu, _button}, scene), do: {:noreply, scene}

  defp resize(scene, width, height) do
    scene
    |> assign(width: round(width), height: round(height))
    |> relayout()
  end

  defp schedule_resize(scene, width, height) do
    if scene.assigns.resize_timer, do: Process.cancel_timer(scene.assigns.resize_timer)

    token = make_ref()
    timer = Process.send_after(self(), {:apply_resize, token}, 50)

    assign(scene,
      resize_timer: timer,
      resize_token: token,
      pending_size: {round(width), round(height)}
    )
  end

  defp relayout(scene) do
    session =
      case scene.assigns.session do
        nil ->
          nil

        session ->
          fit_session(
            session.options,
            session.status,
            scene.assigns.width,
            scene.assigns.height,
            scene.assigns.settings.integer_scaling
          )
      end

    graph_mode =
      case {scene.assigns.mode, scene.assigns.return_mode} do
        {:running, _return_mode} -> :running
        {:loading, :running} -> :running
        {mode, _return_mode} when mode in [:idle, :menu_paused] -> mode
        _other -> :menu_paused
      end

    graph =
      cond do
        session && is_nil(scene.assigns.state_browser) &&
            graph_mode in [:running, :menu_paused] ->
          update_session_graph(
            scene.assigns.graph,
            scene.assigns.width,
            scene.assigns.height,
            session,
            scene.assigns.message,
            graph_mode,
            scene.assigns.settings
          )

        is_nil(session) && is_nil(scene.assigns.state_browser) && graph_mode == :idle ->
          update_idle_graph(
            scene.assigns.graph,
            scene.assigns.width,
            scene.assigns.height,
            scene.assigns.message,
            scene.assigns.settings
          )

        true ->
          build_graph(
            scene.assigns.width,
            scene.assigns.height,
            session,
            scene.assigns.message,
            graph_mode,
            scene.assigns.settings
          )
      end

    {graph, state_browser} =
      case scene.assigns.state_browser do
        nil -> {graph, nil}
        data -> add_state_browser(graph, data, scene.assigns.width, scene.assigns.height)
      end

    scene
    |> assign(graph: graph, session: session, state_browser: state_browser)
    |> push_graph(graph)
  end

  defp open_state_browser(scene) do
    with {:ok, path} <- quick_state_path(scene) do
      rom_hash = scene.assigns.session.status.rom_hash

      data = %{
        paths: SaveState.list(Path.dirname(path), rom_hash),
        rom_hash: rom_hash
      }

      {graph, data} =
        add_state_browser(scene.assigns.graph, data, scene.assigns.width, scene.assigns.height)

      scene
      |> assign(graph: graph, mode: :state_browser, state_browser: data, message: nil)
      |> push_graph(graph)
    else
      {:error, reason} -> put_message(scene, "state browser failed: #{inspect(reason)}")
    end
  end

  defp add_state_browser(graph, data, viewport_width, viewport_height) do
    width = max(viewport_width - 144, 480)
    height = viewport_height |> Kernel.-(260) |> max(330) |> min(440)
    data = Map.put(data, :size, {width, height})

    graph =
      SaveStateBrowser.add_to_graph(graph, data,
        id: :state_browser,
        t: {(viewport_width - width) / 2, (viewport_height - height) / 2}
      )

    {graph, data}
  end

  defp close_state_browser(%{assigns: %{state_browser: nil}} = scene), do: scene

  defp close_state_browser(scene) do
    graph =
      build_graph(
        scene.assigns.width,
        scene.assigns.height,
        scene.assigns.session,
        scene.assigns.message,
        :menu_paused,
        scene.assigns.settings
      )

    scene
    |> assign(graph: graph, mode: :menu_paused, state_browser: nil)
    |> push_graph(graph)
  end

  defp put_message(scene, message) do
    data = status_data(scene.assigns.width, scene.assigns.session, message)
    scene = assign(scene, message: message)

    if Graph.get(scene.assigns.graph, :status_bar) == [],
      do: scene,
      else: update_child(scene, :status_bar, data)
  end

  defp quick_save(%{assigns: %{load_ref: ref}} = scene) when not is_nil(ref),
    do: put_message(scene, "save/load already in progress")

  defp quick_save(scene) do
    with {:ok, path} <- quick_state_path(scene),
         {:ok, snapshot} <- Beamicom.Scenic.Host.snapshot() do
      owner = self()

      {:ok, task} =
        Task.Supervisor.start_child(Beamicom.Scenic.TaskSupervisor, fn ->
          result =
            with :ok <- File.mkdir_p(Path.dirname(path)) do
              SaveState.write(snapshot, path)
            end

          send(owner, {:save_result, result, path})
        end)

      scene
      |> assign(load_ref: task)
      |> put_message("quick-saving #{Path.basename(path)}...")
    else
      {:error, reason} -> put_message(scene, "quick save failed: #{inspect(reason)}")
    end
  end

  defp quick_load(%{assigns: %{load_ref: ref}} = scene) when not is_nil(ref),
    do: put_message(scene, "save/load already in progress")

  defp quick_load(scene) do
    with {:ok, path} <- quick_state_path(scene),
         true <- File.regular?(path) do
      scene
      |> enter_loading()
      |> start_load(path)
    else
      false -> put_message(scene, "no quick state for this ROM")
      {:error, reason} -> put_message(scene, "quick load failed: #{inspect(reason)}")
    end
  end

  defp quick_state_path(%{
         assigns: %{
           session: %{status: %{rom_hash: rom_hash}},
           settings: %{save_state_folder: folder}
         }
       }),
       do: {:ok, SaveState.quick_path(folder, rom_hash)}

  defp quick_state_path(_scene), do: {:error, :no_session}

  defp start_open_dialog(%{assigns: %{dialog_ref: ref}} = scene, _kind, _filters, _message)
       when not is_nil(ref),
       do: scene

  defp start_open_dialog(scene, kind, filters, message) do
    directory =
      if kind == :load_state,
        do: scene.assigns.settings.save_state_folder,
        else: scene.assigns.initial_directory

    task =
      Task.Supervisor.async_nolink(Beamicom.Scenic.TaskSupervisor, fn ->
        FileDialog.open(filters, directory)
      end)

    scene
    |> enter_loading()
    |> assign(dialog_ref: task.ref, dialog_kind: kind)
    |> put_message(message)
  end

  defp start_save_dialog(%{assigns: %{dialog_ref: ref}} = scene, _snapshot)
       when not is_nil(ref),
       do: scene

  defp start_save_dialog(scene, snapshot) do
    directory = scene.assigns.settings.save_state_folder
    default_name = default_save_name(scene.assigns.session)

    task =
      Task.Supervisor.async_nolink(Beamicom.Scenic.TaskSupervisor, fn ->
        with :ok <- File.mkdir_p(directory) do
          FileDialog.save(@save_filters, directory, default_name)
        end
      end)

    scene
    |> enter_loading()
    |> assign(dialog_ref: task.ref, dialog_kind: :save_state, pending_snapshot: snapshot)
    |> put_message("selecting save destination...")
  end

  defp start_directory_dialog(%{assigns: %{dialog_ref: ref}} = scene) when not is_nil(ref),
    do: scene

  defp start_directory_dialog(scene) do
    directory = scene.assigns.settings.save_state_folder

    task =
      Task.Supervisor.async_nolink(Beamicom.Scenic.TaskSupervisor, fn ->
        FileDialog.directory(directory)
      end)

    scene
    |> enter_loading()
    |> assign(dialog_ref: task.ref, dialog_kind: :save_state_folder)
    |> put_message("selecting save-state folder...")
  end

  defp start_load(scene, path) do
    owner = self()

    {:ok, task} =
      Task.Supervisor.start_child(Beamicom.Scenic.TaskSupervisor, fn ->
        send(owner, {:load_result, Beamicom.Scenic.replace(path), path})
      end)

    scene
    |> assign(load_ref: task, initial_directory: Path.dirname(path))
    |> put_message("loading #{Path.basename(path)}...")
  end

  defp start_save(scene, path) do
    owner = self()
    snapshot = scene.assigns.pending_snapshot

    {:ok, task} =
      Task.Supervisor.start_child(Beamicom.Scenic.TaskSupervisor, fn ->
        send(owner, {:save_result, SaveState.write(snapshot, path), path})
      end)

    scene
    |> assign(load_ref: task)
    |> put_message("saving #{Path.basename(path)}...")
  end

  defp default_save_name(nil), do: "beamicom-save.png"

  defp default_save_name(session) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    "#{session.status.rom_hash}-#{stamp}.png"
  end

  defp dialog_label(:save_state), do: "save"
  defp dialog_label(:load_state), do: "state load"
  defp dialog_label(:save_state_folder), do: "folder selection"
  defp dialog_label(_kind), do: "load"

  # scenic_driver_local follows GLFW's name for Escape. Keep the rest of the
  # shell and its child components on the more descriptive internal spelling.
  defp normalize_key(:key_esc), do: :key_escape
  defp normalize_key(key), do: key

  defp controller_key(:up), do: :key_up
  defp controller_key(:down), do: :key_down
  defp controller_key(:left), do: :key_left
  defp controller_key(:right), do: :key_right
  defp controller_key(:a), do: :key_enter
  defp controller_key(:start), do: :key_enter
  defp controller_key(:b), do: :resume
  defp controller_key(_button), do: nil

  defp state_browser_controller_key(:left), do: :key_left
  defp state_browser_controller_key(:right), do: :key_right
  defp state_browser_controller_key(:up), do: :key_left
  defp state_browser_controller_key(:down), do: :key_right
  defp state_browser_controller_key(:a), do: :key_enter
  defp state_browser_controller_key(:start), do: :key_enter
  defp state_browser_controller_key(:b), do: :key_escape
  defp state_browser_controller_key(_button), do: nil

  defp clear_fps(nil), do: nil
  defp clear_fps(session), do: put_in(session.status[:fps], nil)

  defp enter_loading(%{assigns: %{mode: :loading}} = scene), do: scene

  defp enter_loading(scene),
    do: assign(scene, mode: :loading, return_mode: scene.assigns.mode)

  defp restore_mode(%{assigns: %{return_mode: nil}} = scene), do: scene

  defp restore_mode(scene) do
    mode = scene.assigns.return_mode
    scene = assign(scene, mode: mode, return_mode: nil)

    if mode == :menu_paused, do: put_child(scene, :menu_bar, {:open, :game})
    scene
  end

  defp build_graph(width, height, session, _message, :running, _settings) do
    Graph.build()
    |> rect({width, height}, id: :surface_background, fill: :black)
    |> add_game_surface(session, :running)
  end

  defp build_graph(width, height, nil, message, _mode, settings) do
    Graph.build()
    |> Backdrop.add_to_graph({width, height}, id: :backdrop)
    |> Background.add_to_graph({width - 44, height - 44},
      id: :background,
      t: {22, 22},
      scissor: {width - 44, height - 44}
    )
    |> MenuBar.add_to_graph(menu_data(width, nil, settings),
      id: :menu_bar,
      t: {44, 42}
    )
    |> add_logo(width, height, nil)
    |> StatusBar.add_to_graph(
      status_data(width, nil, message),
      id: :status_bar,
      t: {44, height - StatusBar.height() - 32}
    )
  end

  defp build_graph(width, height, session, message, _mode, settings) do
    Graph.build()
    |> rect({width, height}, id: :surface_background, fill: :black)
    |> add_game_surface(session, :running)
    |> MenuBar.add_to_graph(menu_data(width, session, settings), id: :menu_bar, t: {44, 42})
    |> StatusBar.add_to_graph(
      status_data(width, session, message),
      id: :status_bar,
      t: {44, height - StatusBar.height() - 32}
    )
  end

  defp add_game_surface(graph, nil, _mode), do: graph

  defp add_game_surface(graph, session, mode) do
    placement = Map.fetch!(session.placements, mode)
    options = game_surface_options(session, placement, mode)

    GameSurface.add_to_graph(graph, options,
      id: :game_surface,
      t: placement.position,
      scale: placement.scale
    )
  end

  defp update_session_graph(graph, width, height, session, message, mode, settings) do
    placement = Map.fetch!(session.placements, :running)

    graph =
      graph
      |> Graph.modify(:surface_background, &rect(&1, {width, height}))
      |> update_component(
        :game_surface,
        game_surface_options(session, placement, :running),
        t: placement.position,
        scale: placement.scale
      )

    if mode == :menu_paused do
      graph
      |> update_component(:menu_bar, menu_data(width, session, settings))
      |> update_component(:status_bar, status_data(width, session, message),
        t: {44, height - StatusBar.height() - 32}
      )
    else
      graph
    end
  end

  defp update_idle_graph(graph, width, height, message, settings) do
    graph
    |> update_component(:backdrop, {width, height})
    |> update_component(:background, {width - 44, height - 44},
      t: {22, 22},
      scissor: {width - 44, height - 44}
    )
    |> update_component(:menu_bar, menu_data(width, nil, settings), t: {44, 42})
    |> Graph.modify(:logo, fn primitive ->
      Primitive.put_transform(primitive, :translate, {width - 78, height - 116})
    end)
    |> update_component(:status_bar, status_data(width, nil, message),
      t: {44, height - StatusBar.height() - 32}
    )
  end

  defp update_component(graph, id, data, options \\ []) do
    Graph.modify(graph, id, fn
      %{data: {module, _old_data, name}} = primitive ->
        Primitive.put(primitive, {module, data, name}, options)

      primitive ->
        primitive
    end)
  end

  defp game_surface_options(session, placement, mode) do
    session.options
    |> Keyword.put(:output_size, placement.output_size)
    |> Keyword.put(:border?, mode != :running)
  end

  defp add_logo(graph, width, height, nil) do
    text(graph, "BEAMICOM",
      id: :logo,
      fill: Theme.white(),
      font: :beamicom_ui,
      font_size: 52,
      text_align: :right,
      t: {width - 78, height - 116}
    )
  end

  defp menu_data(width, session, settings) do
    session? = session == true or is_map(session)
    state_actions? = session == true or get_in(session, [:status, :system]) in [:nes, :gbc]

    %{
      width: width - 88,
      menus: Menu.model(session?, settings, state_actions?)
    }
  end

  defp status_data(width, session, message) do
    %{
      size: {width - 88, StatusBar.height()},
      rom: if(session, do: Path.basename(session.status.path)),
      fps: if(session, do: Map.get(session.status, :fps)),
      controller: if(session, do: "pad 1: ok", else: "pad 1: --"),
      message: message
    }
  end

  defp fit_session(scene_options, status, width, height, integer_scaling) do
    source_size = Keyword.fetch!(scene_options, :output_size)
    video = Keyword.fetch!(scene_options, :video)
    {pixel_x, pixel_y} = Map.get(video, :pixel_scale, {1, 1})
    base_size = {round(video.width * pixel_x), round(video.height * pixel_y)}
    placement = Layout.fit(base_size, source_size, {0, 0}, {width, height}, integer_scaling)

    %{
      options: scene_options,
      placements: %{
        running: placement,
        hud: placement
      },
      status: status
    }
  end

  defp load_settings do
    case Settings.load() do
      {:ok, settings} -> {settings, nil}
      {:error, reason} -> {Settings.defaults(), "config ignored: #{inspect(reason)}"}
    end
  end

  defp save_setting(scene, key, value, label) do
    settings = Map.put(scene.assigns.settings, key, value)

    case Settings.save(settings) do
      :ok ->
        scene
        |> assign(settings: settings)
        |> update_child(
          :menu_bar,
          menu_data(scene.assigns.width, scene.assigns.session, settings)
        )
        |> put_message("#{label}: #{setting_value(value)}")

      {:error, reason} ->
        put_message(scene, "config save failed: #{inspect(reason)}")
    end
  end

  defp set_video_filter(scene, system, key, value, label) do
    scene = save_setting(scene, key, value, label)

    active_system = get_in(scene.assigns.session, [:status, :system])
    active_filter = get_in(scene.assigns.session, [:status, :video_filter]) || :none

    if active_system == system and active_filter != value and
         Map.fetch!(scene.assigns.settings, key) == value,
       do: start_reconfigure(scene, video_filter: filter_option(value)),
       else: scene
  end

  defp set_nes_enhancement(scene, key, enhancement, label) do
    value = not Map.fetch!(scene.assigns.settings, key)
    scene = save_setting(scene, key, value, label)

    if get_in(scene.assigns.session, [:status, :system]) == :nes &&
         Map.fetch!(scene.assigns.settings, key) == value do
      case Beamicom.Scenic.Host.set_enhancement(enhancement, value) do
        :ok -> scene
        {:error, reason} -> put_message(scene, "setting could not be applied: #{inspect(reason)}")
      end
    else
      scene
    end
  end

  defp set_nes_lighting(scene) do
    value = not scene.assigns.settings.nes_lighting
    scene = save_setting(scene, :nes_lighting, value, "sprite lighting")

    if get_in(scene.assigns.session, [:status, :system]) == :nes &&
         scene.assigns.settings.nes_lighting == value,
       do: start_reconfigure(scene, nes_lighting: value),
       else: scene
  end

  defp start_reconfigure(%{assigns: %{load_ref: ref}} = scene, _options)
       when not is_nil(ref),
       do: put_message(scene, "save/load already in progress")

  defp start_reconfigure(scene, options) do
    owner = self()

    {:ok, task} =
      Task.Supervisor.start_child(Beamicom.Scenic.TaskSupervisor, fn ->
        send(owner, {:reconfigure_result, Beamicom.Scenic.Host.reconfigure(options)})
      end)

    scene
    |> enter_loading()
    |> assign(load_ref: task)
    |> put_message("applying video settings...")
  end

  defp setting_value(:none), do: "none"
  defp setting_value(:composite), do: "Blargg composite"
  defp setting_value(:svideo), do: "S-Video"
  defp setting_value(:rgb), do: "RGB"
  defp setting_value(:pixel_transparency), do: "pixel transparency"
  defp setting_value(true), do: "on"
  defp setting_value(false), do: "off"
  defp setting_value(value) when is_binary(value), do: Path.basename(value)

  defp filter_option(:none), do: nil
  defp filter_option(value), do: value

  defp menu_label(action), do: action |> Atom.to_string() |> String.replace("_", " ")
end
