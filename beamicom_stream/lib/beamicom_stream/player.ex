defmodule BeamicomStream.Player do
  @moduledoc "Owns one emulator runtime and its AV1/Opus RTP broadcast pipeline."
  use GenServer

  alias Beamicom.NES.Runtime
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
         {:ok, pipeline_sup, pipeline} <- start_pipeline(target),
         {:ok, runtime} <- start_runtime(pipeline, rom, opts) do
      {:ok,
       %{
         rom: rom,
         target: target,
         pipeline: pipeline,
         pipeline_sup: pipeline_sup,
         runtime: runtime,
         held: %{1 => MapSet.new(), 2 => MapSet.new()}
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
       target: state.target,
       controls: Map.new(state.held, fn {port, held} -> {port, MapSet.to_list(held)} end)
     }, state}
  end

  def handle_call({:button, button, direction, port}, _from, state)
      when button in @buttons and direction in [:down, :up] and port in [1, 2] do
    held =
      case direction do
        :down -> MapSet.put(state.held[port], button)
        :up -> MapSet.delete(state.held[port], button)
      end

    Runtime.set_buttons(state.runtime, port, MapSet.to_list(held))
    {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
  end

  def handle_call({:button, _button, _direction, _port}, _from, state),
    do: {:reply, :ignore, state}

  def handle_call({:set_buttons, port, buttons}, _from, state) when port in [1, 2] do
    if is_list(buttons) and Enum.all?(buttons, &(&1 in @buttons)) do
      held = MapSet.new(buttons)
      Runtime.set_buttons(state.runtime, port, MapSet.to_list(held))
      {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
    else
      {:reply, {:error, :invalid_buttons}, state}
    end
  end

  def handle_call({:set_buttons, _port, _buttons}, _from, state),
    do: {:reply, {:error, :invalid_buttons}, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state)
      when pid in [state.runtime, state.pipeline, state.pipeline_sup] do
    {:stop, {:child_exit, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.runtime), do: GenServer.stop(state.runtime)
    if Process.alive?(state.pipeline), do: Membrane.Pipeline.terminate(state.pipeline)
    :ok
  end

  defp regular_file(path) do
    if File.regular?(path), do: :ok, else: {:error, {:rom_not_found, path}}
  end

  defp start_pipeline(target) do
    case Membrane.Pipeline.start_link(RtpBroadcast, target: target, owner: self()) do
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

  defp start_runtime(pipeline, rom, opts) do
    case Runtime.start_link(
           rom: rom,
           audio_slices: Keyword.get(opts, :audio_slices, 2),
           name: Keyword.get(opts, :runtime_name, BeamicomStream.Runtime)
         ) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, _reason} = error ->
        Membrane.Pipeline.terminate(pipeline)
        error
    end
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
