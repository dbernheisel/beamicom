defmodule Beamicom.Scenic.Host do
  @moduledoc false

  use GenServer

  alias Beamicom.Scenic.{Player, Shutdown}
  alias Scenic.ViewPort

  def start, do: GenServer.start(__MODULE__, [], name: __MODULE__)
  def load(path, options), do: GenServer.call(__MODULE__, {:load, path, options}, :infinity)
  def replace(path, options), do: GenServer.call(__MODULE__, {:replace, path, options}, :infinity)
  def pause, do: GenServer.call(__MODULE__, :pause)
  def resume, do: GenServer.call(__MODULE__, :resume)
  def reset, do: GenServer.call(__MODULE__, :reset, :infinity)
  def reconfigure(options), do: GenServer.call(__MODULE__, {:reconfigure, options}, :infinity)

  def set_enhancement(enhancement, enabled),
    do: GenServer.call(__MODULE__, {:set_enhancement, enhancement, enabled})

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def unload, do: GenServer.call(__MODULE__, :unload, :infinity)
  def status, do: GenServer.call(__MODULE__, :status)
  def quit, do: GenServer.cast(__MODULE__, :quit)
  def stop, do: GenServer.stop(__MODULE__)

  @impl true
  def init([]) do
    Process.flag(:trap_exit, true)
    config = Application.fetch_env!(:beamicom_scenic, :viewport)

    with {:ok, tasks} <- Task.Supervisor.start_link(name: Beamicom.Scenic.TaskSupervisor),
         {:ok, scenic} <- Scenic.start_link([config]),
         {:ok, viewport} <- ViewPort.info(Keyword.fetch!(config, :name)) do
      viewport_ref = Process.monitor(viewport.pid)

      {:ok,
       %{
         scenic: scenic,
         tasks: tasks,
         viewport: viewport,
         viewport_ref: viewport_ref,
         player: nil,
         session: nil,
         paused: false,
         shell: nil,
         shell_ref: nil,
         error: nil
       }}
    end
  end

  @impl true
  def handle_call({:load, _path, _options}, _from, %{player: player} = state)
      when is_pid(player) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:load, path, options}, _from, state) do
    with {:ok, prepared} <- Player.prepare(path, options),
         {:ok, state} <- start_session(state, prepared) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call({:replace, path, options}, _from, state) do
    case Player.prepare(path, options) do
      {:ok, prepared} ->
        case replace_session(state, prepared) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, %{state | error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call(:pause, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call(:pause, _from, state) do
    :ok = Player.pause(state.player)
    notify_shell(state, {:session_mode, :menu_paused})
    {:reply, :ok, %{state | paused: true}}
  end

  def handle_call(:resume, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call(:resume, _from, state) do
    :ok = Player.resume(state.player)
    notify_shell(state, {:session_mode, :running})
    {:reply, :ok, %{state | paused: false}}
  end

  def handle_call(:reset, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call({:reconfigure, _options}, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call({:reconfigure, options}, _from, state) do
    was_paused = state.paused

    case Player.prepare_reconfigure(state.player, options) do
      {:ok, prepared} ->
        case replace_session(state, prepared, false) do
          {:ok, state} ->
            # The replacement runtime must publish one correctly-sized frame
            # before a paused HUD is rebuilt over it. A timeout is harmless:
            # GameSurface will render the first compatible frame it receives.
            _result = Player.await_video(state.player)

            state =
              if was_paused do
                :ok = Player.pause(state.player)
                %{state | paused: true}
              else
                state
              end

            notify_session_started(state)
            {:reply, :ok, state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, %{state | error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call({:set_enhancement, _enhancement, _enabled}, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call({:set_enhancement, enhancement, enabled}, _from, state) do
    case Player.set_enhancement(state.player, enhancement, enabled) do
      {:ok, options} ->
        session = %{state.session | options: options}
        {:reply, :ok, %{state | session: session}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, %{player: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call(:snapshot, _from, state),
    do: {:reply, Player.snapshot(state.player), state}

  def handle_call(:reset, _from, state) do
    %{path: path, options: options} = state.session

    case Player.prepare(path, options) do
      {:ok, prepared} ->
        case replace_session(state, prepared) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, %{state | error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call(:unload, _from, state) do
    {:reply, :ok, unload_session(state)}
  end

  def handle_call(:status, _from, %{player: nil} = state) do
    {:reply, %{state: :idle, path: nil, error: state.error}, state}
  end

  def handle_call(:status, _from, state) do
    mode = if state.paused, do: :menu_paused, else: :running
    {:reply, Map.put(Player.status(state.player), :state, mode), state}
  end

  @impl true
  def handle_cast(:quit, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:EXIT, scenic, reason}, %{scenic: scenic} = state) do
    {:stop, {:scenic_exit, reason}, state}
  end

  def handle_info({:EXIT, tasks, reason}, %{tasks: tasks} = state) do
    {:stop, {:task_supervisor_exit, reason}, state}
  end

  def handle_info({:EXIT, player, reason}, %{player: player} = state) do
    notify_shell(state, {:session_stopped, session_error(reason)})

    {:noreply, %{state | player: nil, session: nil, paused: false, error: session_error(reason)}}
  end

  def handle_info(
        {:DOWN, ref, :process, viewport_pid, _reason},
        %{viewport: %ViewPort{pid: viewport_pid}, viewport_ref: ref} = state
      ) do
    Shutdown.fun(0)
    {:noreply, %{state | viewport_ref: nil}}
  end

  def handle_info({:register_shell, shell}, state) when is_pid(shell) do
    if state.shell_ref, do: Process.demonitor(state.shell_ref, [:flush])
    shell_ref = Process.monitor(shell)
    state = %{state | shell: shell, shell_ref: shell_ref}

    if state.player, do: notify_session_started(state)

    {:noreply, state}
  end

  def handle_info({:controller_menu, button}, %{paused: true} = state) do
    notify_shell(state, {:controller_menu, button})
    {:noreply, state}
  end

  def handle_info({:controller_menu, _button}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, shell, _reason}, %{shell: shell, shell_ref: ref} = state) do
    {:noreply, %{state | shell: nil, shell_ref: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_child(state.player)
    stop_child(state.scenic)
    stop_child(state.tasks)
    :ok
  end

  defp stop_child(nil), do: :ok

  defp stop_child(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp session_error(reason) when reason in [:normal, :shutdown], do: nil
  defp session_error(reason), do: {:session_exit, reason}

  defp start_session(state, prepared, notify? \\ true) do
    case Player.start_link(prepared: prepared) do
      {:ok, player} ->
        state =
          %{
            state
            | player: player,
              session: %{path: prepared.path, options: prepared.requested_options},
              paused: false,
              error: nil
          }

        if notify?, do: notify_session_started(state)
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_session(state, prepared, notify? \\ true) do
    previous = state.session
    state = unload_session(state, false)

    case start_session(state, prepared, notify?) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        restore_session(state, previous, reason)
    end
  end

  defp restore_session(state, nil, reason), do: {:error, reason, state}

  defp restore_session(state, %{path: path, options: options}, reason) do
    with {:ok, prepared} <- Player.prepare(path, options),
         {:ok, restored_state} <- start_session(state, prepared) do
      {:error, {:replacement_failed, reason}, restored_state}
    else
      {:error, restore_reason} ->
        {:error, {:replacement_and_restore_failed, reason, restore_reason}, state}
    end
  end

  defp unload_session(state, notify? \\ true)

  defp unload_session(%{player: nil} = state, _notify?) do
    %{state | session: nil, paused: false, error: nil}
  end

  defp unload_session(state, notify?) do
    stop_child(state.player)
    if notify?, do: notify_shell(state, {:session_stopped, nil})
    %{state | player: nil, session: nil, paused: false, error: nil}
  end

  defp notify_shell(%{shell: shell}, message) when is_pid(shell), do: send(shell, message)
  defp notify_shell(_state, _message), do: :ok

  defp notify_session_started(state) do
    mode = if state.paused, do: :menu_paused, else: :running

    notify_shell(
      state,
      {:session_started, Player.scene_options(state.player), Player.status(state.player), mode}
    )
  end
end
