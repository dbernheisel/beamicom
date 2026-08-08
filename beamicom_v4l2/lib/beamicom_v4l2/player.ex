defmodule BeamicomV4L2.Player do
  @moduledoc """
  Owns a live Beamicom runtime, framebuffer renderer, V4L2 stream, and controls.

  The default control map accepts browser-style strings and Scenic-style atoms:

      Arrow keys  D-pad
      X            A
      Z            B
      Enter        Start
      Shift        Select
  """

  use GenServer
  require Logger

  alias Beamicom.NES.{Output, Palette, Runtime}
  alias BeamicomV4L2.{Audio, Stream}

  @buttons ~w(up down left right a b start select)a
  @default_controls %{
    "arrowup" => :up,
    "arrowdown" => :down,
    "arrowleft" => :left,
    "arrowright" => :right,
    "x" => :a,
    "z" => :b,
    "enter" => :start,
    "shift" => :select,
    key_up: :up,
    key_down: :down,
    key_left: :left,
    key_right: :right,
    key_x: :a,
    key_z: :b,
    key_enter: :start,
    key_rightshift: :select,
    key_leftshift: :select
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @spec key_event(GenServer.server(), term(), :down | :up, 1 | 2) :: :ok | :ignore
  def key_event(server, key, direction, port \\ 1),
    do: GenServer.call(server, {:key, key, direction, port})

  @spec button_event(GenServer.server(), atom(), :down | :up, 1 | 2) :: :ok | :ignore
  def button_event(server, button, direction, port \\ 1),
    do: GenServer.call(server, {:button, button, direction, port})

  @spec set_buttons(GenServer.server(), 1 | 2, [atom()]) ::
          :ok | {:error, :invalid_buttons}
  def set_buttons(server, port, buttons),
    do: GenServer.call(server, {:set_buttons, port, buttons})

  @doc "Resolve a configured keyboard key to an NES button."
  def button_for(key, controls \\ @default_controls)
  def button_for(key, controls) when is_binary(key), do: Map.get(controls, String.downcase(key))
  def button_for(key, controls), do: Map.get(controls, key)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    rom = options |> Keyword.fetch!(:rom) |> Path.expand()
    framebuffer = Keyword.get(options, :framebuffer, "/dev/fb0")
    output = Keyword.get(options, :output, "/dev/video-beamicom")
    fps = Keyword.get(options, :fps, 60)
    scale = Keyword.get(options, :scale, 3)
    speed = Keyword.get(options, :speed, 1.0)
    controls = Map.merge(@default_controls, Map.new(Keyword.get(options, :controls, %{})))

    with :ok <- regular_file(rom),
         :ok <- valid_scale(scale),
         {:ok, renderer} <- start_renderer(framebuffer, fps, scale),
         :ok <- Output.subscribe_video(),
         audio <- start_audio(options, speed),
         {:ok, runtime} <-
           Runtime.start_link(
             rom: rom,
             speed: speed,
             audio_slices: Keyword.get(options, :audio_slices, 2),
             name: Keyword.get(options, :runtime_name, BeamicomV4L2.Runtime)
           ),
         {:ok, stream} <-
           Stream.start_link(
             framebuffer: framebuffer,
             output: output,
             fps: fps,
             width: 256 * scale,
             height: 240 * scale
           ) do
      {:ok,
       %{
         rom: rom,
         renderer: renderer,
         runtime: runtime,
         stream: stream,
         audio: audio,
         controls: controls,
         held: %{1 => MapSet.new(), 2 => MapSet.new()},
         scale: scale,
         frame: -1,
         renderer_log: ""
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      rom: state.rom,
      frame: state.frame,
      scale: state.scale,
      audio: audio_status(state.audio),
      controls: Map.new(state.held, fn {port, held} -> {port, MapSet.to_list(held)} end),
      stream: Stream.status(state.stream)
    }

    {:reply, reply, state}
  end

  def handle_call({:key, key, direction, port}, _from, state)
      when direction in [:down, :up] and port in [1, 2] do
    case button_for(key, state.controls) do
      nil -> {:reply, :ignore, state}
      button -> update_button(state, port, button, direction)
    end
  end

  def handle_call({:key, _key, _direction, _port}, _from, state),
    do: {:reply, :ignore, state}

  def handle_call({:button, button, direction, port}, _from, state)
      when button in @buttons and direction in [:down, :up] and port in [1, 2],
      do: update_button(state, port, button, direction)

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
  def handle_info({:frame, number}, state) do
    case Output.latest() do
      %{number: ^number} = framebuffer ->
        case Port.command(state.renderer, Palette.to_rgb(framebuffer)) do
          true -> {:noreply, %{state | frame: number}}
          false -> {:stop, :framebuffer_renderer_closed, state}
        end

      _frame ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, data}}, %{renderer: port} = state) do
    {:noreply, %{state | renderer_log: tail(state.renderer_log <> data)}}
  end

  def handle_info({port, {:exit_status, status}}, %{renderer: port} = state) do
    Logger.error("framebuffer renderer exited with status #{status}: #{state.renderer_log}")
    {:stop, {:framebuffer_renderer_exit, status}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{audio: %{pid: pid}} = state) do
    error = inspect(reason)

    if reason not in [:normal, :shutdown] do
      Logger.warning("audio playback stopped: #{error}; video will continue")
    end

    {:noreply, %{state | audio: %{enabled: true, pid: nil, error: error}}}
  end

  def handle_info({:EXIT, pid, reason}, state) when pid in [state.runtime, state.stream],
    do: {:stop, {:child_exit, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.audio.pid) and Process.alive?(state.audio.pid),
      do: GenServer.stop(state.audio.pid)

    if is_pid(state.stream) and Process.alive?(state.stream), do: GenServer.stop(state.stream)
    if is_pid(state.runtime) and Process.alive?(state.runtime), do: GenServer.stop(state.runtime)
    if is_port(state.renderer) and Port.info(state.renderer), do: Port.close(state.renderer)
    :ok
  end

  defp update_button(state, port, button, direction) do
    held =
      case direction do
        :down -> MapSet.put(state.held[port], button)
        :up -> MapSet.delete(state.held[port], button)
      end

    Runtime.set_buttons(state.runtime, port, MapSet.to_list(held))
    {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
  end

  defp start_renderer(framebuffer, fps, scale) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, "ffmpeg is required to render Beamicom into #{framebuffer}"}

      executable ->
        args =
          ~w(-hide_banner -loglevel error -f rawvideo -pixel_format rgb24 -video_size 256x240) ++
            ["-framerate", Integer.to_string(fps)] ++
            [
              "-i",
              "pipe:0",
              "-vf",
              "scale=#{256 * scale}:#{240 * scale}:flags=neighbor",
              "-pix_fmt",
              "bgra",
              "-f",
              "fbdev",
              framebuffer
            ]

        {:ok,
         Port.open(
           {:spawn_executable, executable},
           [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
         )}
    end
  end

  defp start_audio(options, speed) do
    if Keyword.get(options, :audio, true) do
      audio_options = [speed: speed]

      audio_options =
        case Keyword.fetch(options, :audio_command) do
          {:ok, command} -> Keyword.put(audio_options, :command, command)
          :error -> audio_options
        end

      case Audio.start_link(audio_options) do
        {:ok, pid} ->
          %{enabled: true, pid: pid, error: nil}

        {:error, reason} ->
          error = inspect(reason)
          Logger.warning("audio playback disabled: #{error}")
          %{enabled: true, pid: nil, error: error}

        :ignore ->
          %{enabled: true, pid: nil, error: "audio player declined to start"}
      end
    else
      %{enabled: false, pid: nil, error: nil}
    end
  end

  defp audio_status(%{enabled: false}), do: %{enabled: false, running: false, error: nil}

  defp audio_status(%{pid: pid} = audio) when is_pid(pid) do
    try do
      Map.merge(%{enabled: true, error: audio.error}, Audio.status(pid))
    catch
      :exit, _reason -> %{enabled: true, running: false, error: audio.error || "audio stopped"}
    end
  end

  defp audio_status(audio),
    do: %{enabled: audio.enabled, running: false, error: audio.error}

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, "ROM is not a regular file: #{path}"}
      {:error, reason} -> {:error, "cannot read ROM #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp valid_scale(scale) when is_integer(scale) and scale in 1..8, do: :ok
  defp valid_scale(_scale), do: {:error, "scale must be an integer from 1 through 8"}

  defp tail(log) when byte_size(log) <= 4_096, do: log
  defp tail(log), do: binary_part(log, byte_size(log) - 4_096, 4_096)
end
