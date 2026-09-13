defmodule BeamicomPhx.Emulator do
  @moduledoc """
  Owns the server's active NES or Game Boy runtime and media profile.

  ROMs are fully parsed before replacement starts. Format-family transitions
  replace the encoder and tell browser WebRTC peers to remount with fresh
  signaling. Same-family loads retain their output/encoder subscriptions and
  rebase reset frame counters monotonically. A failed preparation leaves the
  active session untouched; a later startup failure restores its machine state.
  """

  use GenServer

  alias Beamicom.GB.{Machine, PPU}
  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{Input, Output}
  alias Beamicom.NES.{Console, Runtime}
  alias Beamicom.NES.Output, as: NESOutput
  alias BeamicomStream.Core
  alias BeamicomStream.Runtime, as: GBRuntime

  @runtime_sup BeamicomPhx.RuntimeSupervisor
  @topic "emulator-profile"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Prevalidate and load a supported ROM path, preserving the active game on failure."
  def load(rom_path, opts \\ []) when is_binary(rom_path) and is_list(opts) do
    notify_from =
      Keyword.get(opts, :notify_from) ||
        if Keyword.get(opts, :exclude_caller, false), do: self()

    GenServer.call(
      __MODULE__,
      {:load, rom_path, Keyword.get(opts, :rom_name), notify_from},
      30_000
    )
  end

  @doc "Resume an NES save, replacing whichever system is active."
  def load_console(%Console{} = console), do: GenServer.call(__MODULE__, {:load_console, console})

  @doc "Resume a Game Boy save, replacing whichever system is active."
  def load_machine(%Machine{} = machine), do: GenServer.call(__MODULE__, {:load_machine, machine})

  @doc "Stop the active runtime and encoder session."
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "Whether a core runtime is currently active."
  def loaded?, do: GenServer.call(__MODULE__, :loaded?)

  @doc "The active system family (:nes or :gbc), or nil."
  def system, do: GenServer.call(__MODULE__, :system)

  @doc "Current output/video/audio configuration for a browser encoder."
  def profile, do: GenServer.call(__MODULE__, :profile)

  @doc "Subscribe to emulator profile changes."
  def subscribe, do: Phoenix.PubSub.subscribe(BeamicomPhx.PubSub, @topic)

  @doc """
  Set one browser input source's complete held state.

  NES accepts ports 1 and 2. Game Boy accepts only port 1; every other port
  returns an unsupported-port error.
  """
  def press(port, buttons) when is_integer(port) and is_list(buttons),
    do: GenServer.call(__MODULE__, {:press, self(), port, buttons})

  @doc "Set the remote browser seat's held state using an atomic system-aware port mapping."
  def press_remote(buttons) when is_list(buttons),
    do: GenServer.call(__MODULE__, {:press, self(), :remote, buttons})

  @doc "Atomically identifies the active core and captures its machine plus visible frame."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(_opts), do: {:ok, %{session: nil, inputs: %{}, input_monitors: %{}}}

  @impl true
  def handle_call({:load, path, rom_name, notify_from}, _from, state) do
    case prepare(path, rom_name) do
      {:ok, prepared} -> replace(Map.put(prepared, :notify_from, notify_from), state)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:load_console, console}, _from, state) do
    {:ok, core} = Core.resolve("save.nes")
    replace(%{core: core, machine: console, rom_name: "NES save", notify_from: nil}, state)
  end

  def handle_call({:load_machine, machine}, _from, state) do
    {:ok, core} = Core.resolve("save.gbc")
    title = machine.bus.cartridge.header.title
    rom_name = if title == <<>>, do: "Game Boy save", else: title
    replace(%{core: core, machine: machine, rom_name: rom_name, notify_from: nil}, state)
  end

  def handle_call(:stop, _from, state) do
    cleanup_session(state.session)
    clear_input_monitors(state.input_monitors)
    notify(nil)
    {:reply, :ok, %{state | session: nil, inputs: %{}, input_monitors: %{}}}
  end

  def handle_call(:loaded?, _from, state), do: {:reply, not is_nil(state.session), state}
  def handle_call(:system, _from, state), do: {:reply, session_system(state.session), state}
  def handle_call(:profile, _from, state), do: {:reply, session_profile(state.session), state}

  def handle_call(
        :snapshot,
        _from,
        %{session: %{core: %Core{id: :nes}, runtime: runtime}} = state
      ) do
    reply =
      try do
        {:ok, Runtime.snapshot(runtime)}
      catch
        :exit, _reason -> {:error, :not_loaded}
      end

    {:reply, reply, state}
  end

  def handle_call(
        :snapshot,
        _from,
        %{session: %{core: %Core{id: :gbc}, runtime: runtime}} = state
      ) do
    reply =
      try do
        machine = GBRuntime.snapshot(runtime)
        frame = if machine.bus.ppu.frame_number == 0, do: nil, else: PPU.frame(machine.bus.ppu)
        {:ok, {machine, frame}}
      catch
        :exit, _reason -> {:error, :not_loaded}
      end

    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:error, :not_loaded}, state}

  def handle_call({:press, _source, _port, _buttons}, _from, %{session: nil} = state),
    do: {:reply, {:error, :not_loaded}, state}

  def handle_call({:press, source, port, buttons}, _from, state) do
    if supported_port?(state.session, port) do
      state = update_input(state, source, port, buttons)
      physical_port = physical_port(state.session, port)

      dispatch_port(
        state.session,
        physical_port,
        aggregate(state.session, state.inputs, physical_port)
      )

      {:reply, :ok, state}
    else
      {:reply, {:error, :unsupported_port}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, source, _reason}, state) do
    cond do
      state.session && ref == state.session.runtime_ref ->
        cleanup_after_runtime_exit(state.session)
        notify(nil)
        {:noreply, clear_inputs(%{state | session: nil})}

      state.session && ref == state.session.output_ref ->
        cleanup_after_output_exit(state.session)
        notify(nil)
        {:noreply, clear_inputs(%{state | session: nil})}

      state.session && ref == state.session.broadcast_ref ->
        stop_broadcast_supervisor(state.session.broadcast)
        session = %{state.session | broadcast: nil, broadcast_ref: nil}
        Process.send_after(self(), {:restart_broadcast, session.runtime}, 100)
        {:noreply, %{state | session: session}}

      state.input_monitors[source] == ref ->
        {:noreply, drop_input_source(state, source)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:restart_broadcast, runtime},
        %{session: %{runtime: runtime, broadcast: nil}} = state
      ),
      do: {:noreply, restart_broadcast(state)}

  def handle_info({:restart_broadcast, _stale_runtime}, state), do: {:noreply, state}

  defp prepare(path, rom_name) do
    with {:ok, core} <- Core.resolve(rom_name || path),
         {:ok, media} <- File.read(path),
         {:ok, prepared} <- prepare_core(core, media) do
      {:ok, Map.put(prepared, :rom_name, rom_name || Path.basename(path))}
    end
  end

  defp prepare_core(%Core{runtime: :nes} = core, media) do
    try do
      {:ok, %{core: core, machine: Console.load_binary(media)}}
    rescue
      error -> {:error, {:invalid_rom, Exception.message(error)}}
    end
  end

  defp prepare_core(%Core{runtime: :host, system: GBSystem} = core, media) do
    case GBRuntime.load(GBSystem, media, []) do
      {:ok, machine} -> {:ok, %{core: core, machine: machine}}
      {:error, _reason} = error -> error
    end
  end

  defp replace(prepared, state) do
    old = demonitor_session(state.session)
    changed? = session_system(old) != prepared.core.id

    case stage_output(prepared.core, old, changed?) do
      {:ok, output, new_output?} ->
        case stage_broadcast(prepared.core, output, old, changed?) do
          {:ok, broadcast} ->
            replace_runtime(prepared, output, new_output?, broadcast, old, state, changed?)

          {:error, reason} ->
            if new_output?, do: stop_output(output)
            old = restore_broadcast(old, changed?) |> monitor_session()
            {:reply, {:error, reason}, %{state | session: old}}
        end

      {:error, reason} ->
        old = monitor_session(old)
        {:reply, {:error, reason}, %{state | session: old}}
    end
  end

  defp replace_runtime(prepared, output, new_output?, broadcast, old, state, changed?) do
    restart = restart_machine(old)
    stop_runtime(old)

    case start_runtime(prepared, output) do
      {:ok, runtime} ->
        cleanup_replaced(old, changed?)

        session =
          monitor_session(%{
            core: prepared.core,
            runtime: runtime,
            output: output,
            rom_name: Map.get(prepared, :rom_name),
            owns_output?: prepared.core.id == :gbc,
            broadcast: broadcast
          })

        state =
          state
          |> normalize_inputs(prepared.core.id)
          |> Map.put(:session, session)
          |> dispatch_all_inputs()

        if changed?,
          do: notify(profile(session), prepared.notify_from),
          else: notify_loaded(profile(session), prepared.notify_from)

        {:reply, :ok, state}

      {:error, reason} ->
        if changed?, do: stop_broadcast(broadcast)
        if new_output?, do: stop_output(output)
        restored = restore(old, restart, changed?)
        if old && is_nil(restored), do: cleanup_failed_restore(old)
        {:reply, {:error, reason}, %{state | session: restored}}
    end
  end

  defp stage_output(%Core{id: :nes}, _old, _changed?) do
    case Process.whereis(NESOutput) do
      nil -> {:error, :nes_output_unavailable}
      _pid -> {:ok, NESOutput, false}
    end
  end

  defp stage_output(%Core{id: :gbc}, %{core: %Core{id: :gbc}, output: output}, false),
    do: {:ok, output, false}

  defp stage_output(%Core{id: :gbc}, _old, true) do
    case DynamicSupervisor.start_child(@runtime_sup, child(Output, [name: nil], :worker)) do
      {:ok, output} -> {:ok, output, true}
      {:error, _reason} = error -> error
    end
  end

  defp start_broadcast(core, output) do
    case BeamicomPhx.RtpConfig.target() do
      nil ->
        {:ok, nil}

      target ->
        opts = [
          target: target,
          output: output,
          video: core.capabilities.video,
          audio: core.capabilities.audio,
          pts_offset_ns: rtp_pts_offset()
        ]

        case DynamicSupervisor.start_child(
               @runtime_sup,
               pipeline_child(BeamicomStream.AV.RtpBroadcast, opts)
             ) do
          {:ok, supervisor, pipeline} -> {:ok, %{supervisor: supervisor, pipeline: pipeline}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp stage_broadcast(_core, _output, %{broadcast: broadcast}, false),
    do: {:ok, broadcast}

  defp stage_broadcast(core, output, old, true) do
    stop_broadcast(old && old.broadcast)
    start_broadcast(core, output)
  end

  defp start_runtime(%{core: %Core{runtime: :nes}, machine: console}, _output) do
    DynamicSupervisor.start_child(@runtime_sup, child(Runtime, [console: console], :worker))
  end

  defp start_runtime(
         %{core: %Core{runtime: :host, system: GBSystem}, machine: machine},
         output
       ) do
    opts = [system: GBSystem, machine: machine, media: <<>>, output: output, name: nil]
    DynamicSupervisor.start_child(@runtime_sup, child(GBRuntime, opts, :worker))
  end

  defp restart_machine(nil), do: nil

  defp restart_machine(%{core: %Core{id: :nes}, runtime: runtime}),
    do: elem(Runtime.snapshot(runtime), 0)

  defp restart_machine(%{core: %Core{id: :gbc}, runtime: runtime}),
    do: GBRuntime.snapshot(runtime)

  defp restore(nil, _restart, _changed?), do: nil

  defp restore(old, restart, changed?) do
    case start_runtime(%{core: old.core, machine: restart}, old.output) do
      {:ok, runtime} ->
        old
        |> Map.put(:runtime, runtime)
        |> restore_broadcast(changed?)
        |> monitor_session()

      {:error, _reason} ->
        nil
    end
  end

  defp restore_broadcast(nil, _changed?), do: nil
  defp restore_broadcast(old, false), do: old

  defp restore_broadcast(old, true) do
    case start_broadcast(old.core, old.output) do
      {:ok, broadcast} -> %{old | broadcast: broadcast}
      {:error, _reason} -> %{old | broadcast: nil}
    end
  end

  defp supported_port?(%{core: %Core{id: id}}, :remote) when id in [:nes, :gbc], do: true
  defp supported_port?(%{core: %Core{id: :nes}}, port), do: port in [1, 2]
  defp supported_port?(%{core: %Core{id: :gbc}}, port), do: port == 1
  defp supported_port?(_session, _port), do: false

  defp update_input(state, source, port, buttons) do
    key = {source, port}
    buttons = MapSet.new(buttons)

    inputs =
      if MapSet.size(buttons) == 0,
        do: Map.delete(state.inputs, key),
        else: Map.put(state.inputs, key, buttons)

    %{state | inputs: inputs}
    |> update_input_monitor(source)
  end

  defp update_input_monitor(state, source) do
    held? = Enum.any?(state.inputs, fn {{pid, _port}, _buttons} -> pid == source end)

    case {held?, state.input_monitors[source]} do
      {true, nil} ->
        %{state | input_monitors: Map.put(state.input_monitors, source, Process.monitor(source))}

      {false, ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | input_monitors: Map.delete(state.input_monitors, source)}

      _ ->
        state
    end
  end

  defp drop_input_source(state, source) do
    ports =
      state.inputs
      |> Map.keys()
      |> Enum.filter(fn {pid, _target} -> pid == source end)
      |> Enum.map(fn {_pid, target} -> physical_port(state.session, target) end)
      |> Enum.uniq()

    inputs = Map.reject(state.inputs, fn {{pid, _target}, _buttons} -> pid == source end)
    state = %{state | inputs: inputs, input_monitors: Map.delete(state.input_monitors, source)}

    Enum.each(
      ports,
      &dispatch_port(state.session, &1, aggregate(state.session, inputs, &1))
    )

    state
  end

  defp aggregate(session, inputs, port) do
    Enum.reduce(inputs, MapSet.new(), fn
      {{_source, target}, buttons}, held ->
        if physical_port(session, target) == port,
          do: MapSet.union(held, buttons),
          else: held
    end)
    |> MapSet.to_list()
  end

  defp physical_port(%{core: %Core{id: :nes}}, :remote), do: 2
  defp physical_port(%{core: %Core{id: :gbc}}, :remote), do: 1
  defp physical_port(_session, port) when is_integer(port), do: port

  defp dispatch_port(%{core: %Core{id: :nes}, runtime: runtime}, port, buttons),
    do: Runtime.set_buttons(runtime, port, buttons)

  defp dispatch_port(%{core: %Core{id: :gbc}, runtime: runtime}, 1, buttons),
    do: GBRuntime.set_input(runtime, Input.new(1, buttons))

  defp dispatch_port(_session, _port, _buttons), do: :ok

  defp dispatch_all_inputs(%{session: nil} = state), do: state

  defp dispatch_all_inputs(state) do
    ports = if state.session.core.id == :nes, do: [1, 2], else: [1]

    Enum.each(
      ports,
      &dispatch_port(state.session, &1, aggregate(state.session, state.inputs, &1))
    )

    state
  end

  defp normalize_inputs(state, :nes), do: state

  defp normalize_inputs(state, :gbc) do
    inputs =
      Map.reject(state.inputs, fn
        {{_source, :remote}, _buttons} -> false
        {{_source, port}, _buttons} -> port != 1
      end)

    state = %{state | inputs: inputs}

    Enum.reduce(Map.keys(state.input_monitors), state, fn source, acc ->
      update_input_monitor(acc, source)
    end)
  end

  defp monitor_session(nil), do: nil

  defp monitor_session(session) do
    Map.merge(session, %{
      runtime_ref: Process.monitor(session.runtime),
      output_ref: monitor_owned_output(session),
      broadcast_ref: monitor_broadcast(session.broadcast)
    })
  end

  defp monitor_owned_output(%{owns_output?: true, output: output}), do: Process.monitor(output)
  defp monitor_owned_output(_session), do: nil
  defp monitor_broadcast(nil), do: nil
  defp monitor_broadcast(%{pipeline: pipeline}), do: Process.monitor(pipeline)

  defp restart_broadcast(%{session: session} = state) do
    case start_broadcast(session.core, session.output) do
      {:ok, broadcast} ->
        session = %{session | broadcast: broadcast, broadcast_ref: monitor_broadcast(broadcast)}
        %{state | session: session}

      {:error, _reason} ->
        Process.send_after(self(), {:restart_broadcast, session.runtime}, 1_000)
        state
    end
  end

  defp demonitor_session(nil), do: nil

  defp demonitor_session(session) do
    Enum.each([session[:runtime_ref], session[:output_ref], session[:broadcast_ref]], fn
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end)

    Map.merge(session, %{runtime_ref: nil, output_ref: nil, broadcast_ref: nil})
  end

  defp stop_runtime(nil), do: :ok

  defp stop_runtime(%{runtime: runtime}),
    do: DynamicSupervisor.terminate_child(@runtime_sup, runtime)

  defp stop_output(output) when is_pid(output),
    do: DynamicSupervisor.terminate_child(@runtime_sup, output)

  defp stop_broadcast(nil), do: :ok

  defp stop_broadcast(%{supervisor: supervisor, pipeline: pipeline}) do
    try do
      Membrane.Pipeline.terminate(pipeline)
    catch
      :exit, _reason -> :ok
    end

    DynamicSupervisor.terminate_child(@runtime_sup, supervisor)
    :ok
  end

  defp stop_broadcast_supervisor(nil), do: :ok

  defp stop_broadcast_supervisor(%{supervisor: supervisor}),
    do: DynamicSupervisor.terminate_child(@runtime_sup, supervisor)

  defp cleanup_session(nil), do: :ok

  defp cleanup_session(session) do
    session = demonitor_session(session)
    stop_runtime(session)
    stop_broadcast(session.broadcast)
    if session.owns_output?, do: stop_output(session.output)
    :ok
  end

  defp cleanup_replaced(nil, _changed?), do: :ok

  defp cleanup_replaced(session, changed?) do
    if changed? and session.owns_output?, do: stop_output(session.output)
    :ok
  end

  defp cleanup_after_runtime_exit(session) do
    session = demonitor_session(session)
    stop_broadcast(session.broadcast)
    if session.owns_output?, do: stop_output(session.output)
  end

  defp cleanup_after_output_exit(session) do
    session = demonitor_session(session)
    stop_runtime(session)
    stop_broadcast(session.broadcast)
  end

  defp cleanup_failed_restore(session) do
    cleanup_session(session)
    notify(nil)
  end

  defp clear_input_monitors(monitors) do
    Enum.each(monitors, fn {_source, ref} -> Process.demonitor(ref, [:flush]) end)
  end

  defp clear_inputs(state) do
    clear_input_monitors(state.input_monitors)
    %{state | inputs: %{}, input_monitors: %{}}
  end

  defp profile(session) do
    %{
      system: session.core.id,
      output: session.output,
      video: session.core.capabilities.video,
      audio: session.core.capabilities.audio,
      rom_name: session.rom_name
    }
  end

  defp session_profile(nil), do: nil
  defp session_profile(session), do: profile(session)
  defp session_system(nil), do: nil
  defp session_system(%{core: core}), do: core.id

  defp notify(profile),
    do: Phoenix.PubSub.broadcast(BeamicomPhx.PubSub, @topic, {:emulator_profile, profile})

  defp notify(profile, nil), do: notify(profile)

  defp notify(profile, from),
    do:
      Phoenix.PubSub.broadcast_from(
        BeamicomPhx.PubSub,
        from,
        @topic,
        {:emulator_profile, profile}
      )

  defp notify_loaded(profile),
    do: Phoenix.PubSub.broadcast(BeamicomPhx.PubSub, @topic, {:emulator_loaded, profile})

  defp notify_loaded(profile, nil), do: notify_loaded(profile)

  defp notify_loaded(profile, from),
    do:
      Phoenix.PubSub.broadcast_from(
        BeamicomPhx.PubSub,
        from,
        @topic,
        {:emulator_loaded, profile}
      )

  defp rtp_pts_offset do
    started_ns = System.convert_time_unit(:erlang.system_info(:start_time), :native, :nanosecond)
    System.monotonic_time(:nanosecond) - started_ns
  end

  defp child(module, opts, type) do
    %{
      id: make_ref(),
      start: {module, :start_link, [opts]},
      restart: :temporary,
      type: type
    }
  end

  defp pipeline_child(module, opts) do
    %{
      id: make_ref(),
      start: {Membrane.Pipeline, :start_link, [module, opts]},
      restart: :temporary,
      type: :supervisor
    }
  end
end
