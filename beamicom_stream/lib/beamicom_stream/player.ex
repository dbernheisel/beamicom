defmodule BeamicomStream.Player do
  @moduledoc "Owns one emulator runtime and its AV1/Opus RTP broadcast pipeline."
  use GenServer

  alias Beamicom.Host.{Input, InputCapabilities, Output}
  alias Beamicom.NES.Runtime, as: NESRuntime
  alias BeamicomStream.{Core, Runtime}
  alias BeamicomStream.AV.RtpBroadcast

  @buttons ~w(up down left right a b start select)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def button_event(server, button, direction, port \\ 1),
    do: GenServer.call(server, {:button, button, direction, port})

  def set_buttons(server, port, buttons),
    do: GenServer.call(server, {:set_buttons, port, buttons})

  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    rom = opts |> Keyword.fetch!(:rom) |> Path.expand()
    target = Keyword.get(opts, :target, {{127, 0, 0, 1}, 5_000})

    with :ok <- regular_file(rom),
         {:ok, core} <- Core.resolve(rom),
         {:ok, components} <- start_components(core, target, rom, opts) do
      %{pipeline: pipeline, pipeline_sup: pipeline_sup, runtime: runtime} = components

      {:ok,
       %{
         rom: rom,
         system: core.id,
         runtime_kind: core.runtime,
         target: target,
         pipeline: pipeline,
         pipeline_sup: pipeline_sup,
         runtime: runtime,
         output: components.output,
         owned_output: components.owned_output,
         input: core.capabilities.input,
         held: empty_controls(core.capabilities.input)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       rom: state.rom,
       system: state.system,
       target: state.target,
       controls: Map.new(state.held, fn {port, held} -> {port, MapSet.to_list(held)} end)
     }, state}
  end

  def handle_call({:button, button, direction, port}, _from, state)
      when button in @buttons and direction in [:down, :up] do
    with {:ok, current} <- Map.fetch(state.held, port),
         true <- supported?(state.input, port, button) do
      held =
        if direction == :down,
          do: MapSet.put(current, button),
          else: MapSet.delete(current, button)

      dispatch_input(state.runtime_kind, state.runtime, port, held)
      {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
    else
      _unsupported -> {:reply, :ignore, state}
    end
  end

  def handle_call({:button, _button, _direction, _port}, _from, state),
    do: {:reply, :ignore, state}

  def handle_call({:set_buttons, port, buttons}, _from, state) do
    if is_list(buttons) and Map.has_key?(state.held, port) and
         Enum.all?(buttons, &supported?(state.input, port, &1)) do
      held = MapSet.new(buttons)
      dispatch_input(state.runtime_kind, state.runtime, port, held)
      {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
    else
      {:reply, {:error, :invalid_buttons}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state)
      when pid in [state.runtime, state.pipeline, state.pipeline_sup, state.owned_output] do
    {:stop, {:child_exit, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.runtime), do: GenServer.stop(state.runtime)
    if Process.alive?(state.pipeline), do: Membrane.Pipeline.terminate(state.pipeline)
    stop_output(state.owned_output)
    :ok
  end

  defp regular_file(path) do
    if File.regular?(path), do: :ok, else: {:error, {:rom_not_found, path}}
  end

  defp start_pipeline(target, output, capabilities) do
    case Membrane.Pipeline.start_link(RtpBroadcast,
           target: target,
           owner: self(),
           output: output,
           video: capabilities.video,
           audio: capabilities.audio
         ) do
      {:ok, supervisor, pipeline} ->
        case await_sources() do
          :ok ->
            {:ok, supervisor, pipeline}

          {:error, _reason} = error ->
            Membrane.Pipeline.terminate(pipeline)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp start_runtime(%Core{runtime: :nes}, rom, opts, _output) do
    NESRuntime.start_link(
      rom: rom,
      audio_slices: Keyword.get(opts, :audio_slices, 2),
      name: Keyword.get(opts, :runtime_name, BeamicomStream.Runtime)
    )
  end

  defp start_runtime(%Core{runtime: :host, system: system}, rom, opts, output) do
    Runtime.start_link(
      system: system,
      media: rom,
      machine: Keyword.fetch!(opts, :prepared_machine),
      output: output,
      name: Keyword.get(opts, :runtime_name)
    )
  end

  defp start_components(%Core{runtime: :host, system: system} = core, target, rom, opts) do
    with {:ok, media} <- File.read(rom),
         {:ok, machine} <- Runtime.load(system, media, Keyword.get(opts, :load_options, [])) do
      start_loaded_components(core, target, rom, Keyword.put(opts, :prepared_machine, machine))
    end
  end

  defp start_components(%Core{runtime: :nes} = core, target, rom, opts),
    do: start_loaded_components(core, target, rom, opts)

  defp start_loaded_components(core, target, rom, opts) do
    with {:ok, output, owned_output} <- start_output(core) do
      case start_pipeline(target, output, core.capabilities) do
        {:ok, pipeline_sup, pipeline} ->
          case start_runtime(core, rom, opts, output) do
            {:ok, runtime} ->
              {:ok,
               %{
                 output: output,
                 owned_output: owned_output,
                 pipeline_sup: pipeline_sup,
                 pipeline: pipeline,
                 runtime: runtime
               }}

            {:error, _reason} = error ->
              Membrane.Pipeline.terminate(pipeline)
              stop_output(owned_output)
              error
          end

        {:error, _reason} = error ->
          stop_output(owned_output)
          error
      end
    end
  end

  defp start_output(%Core{id: :nes}) do
    case Process.whereis(Beamicom.NES.Output) do
      nil -> {:error, :nes_output_unavailable}
      _pid -> {:ok, Beamicom.NES.Output, nil}
    end
  end

  defp start_output(%Core{id: :gbc}) do
    case Output.start_link([]) do
      {:ok, output} -> {:ok, output, output}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_input(:nes, runtime, port, held),
    do: NESRuntime.set_buttons(runtime, port, MapSet.to_list(held))

  defp dispatch_input(:host, runtime, port, held),
    do: Runtime.set_input(runtime, Input.new(port, held))

  defp empty_controls(%InputCapabilities{ports: ports}),
    do: Map.new(ports, fn {port, _controls} -> {port, MapSet.new()} end)

  defp supported?(%InputCapabilities{ports: ports}, port, button) do
    case Map.fetch(ports, port) do
      {:ok, controls} -> MapSet.member?(controls, button)
      :error -> false
    end
  end

  defp stop_output(nil), do: :ok

  defp stop_output(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp await_sources(ready \\ MapSet.new()) do
    if MapSet.equal?(ready, MapSet.new([:video, :audio])) do
      :ok
    else
      receive do
        {:beamicom_stream_source_ready, kind} -> await_sources(MapSet.put(ready, kind))
      after
        5_000 -> {:error, :pipeline_start_timeout}
      end
    end
  end
end
