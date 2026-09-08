defmodule BeamicomV4L2.Player do
  @moduledoc """
  Owns one emulator runtime, framebuffer renderer, V4L2 stream, and controls.

  The emulator system is selected once from the ROM extension before any
  framebuffer, video, or audio device is opened.
  """

  use GenServer
  require Logger

  alias Beamicom.Host.{Input, InputCapabilities, Output, VideoFrame}
  alias Beamicom.NES.Output, as: NESOutput
  alias Beamicom.NES.Runtime, as: NESRuntime
  alias BeamicomV4L2.{Audio, Core, Runtime, Stream, Video}

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
    GenServer.start_link(__MODULE__, options, name_option(name))
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @spec key_event(GenServer.server(), term(), :down | :up, pos_integer()) :: :ok | :ignore
  def key_event(server, key, direction, port \\ 1),
    do: GenServer.call(server, {:key, key, direction, port})

  @spec button_event(GenServer.server(), atom(), :down | :up, pos_integer()) :: :ok | :ignore
  def button_event(server, button, direction, port \\ 1),
    do: GenServer.call(server, {:button, button, direction, port})

  @spec set_buttons(GenServer.server(), pos_integer(), [atom()]) ::
          :ok | {:error, :invalid_buttons}
  def set_buttons(server, port, buttons),
    do: GenServer.call(server, {:set_buttons, port, buttons})

  @doc "Resolve a configured keyboard key to an emulator button."
  def button_for(key, controls \\ @default_controls)
  def button_for(key, controls) when is_binary(key), do: Map.get(controls, String.downcase(key))
  def button_for(key, controls), do: Map.get(controls, key)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    rom = options |> Keyword.fetch!(:rom) |> Path.expand()
    framebuffer = Keyword.get(options, :framebuffer, "/dev/fb0")
    output_device = Keyword.get(options, :output, "/dev/video-beamicom")
    fps = Keyword.get(options, :fps, 60)
    scale = Keyword.get(options, :scale, 3)
    speed = Keyword.get(options, :speed, 1.0)
    controls = Map.merge(@default_controls, Map.new(Keyword.get(options, :controls, %{})))

    with :ok <- regular_file(rom),
         {:ok, core} <- Core.resolve(rom),
         :ok <- valid_options(framebuffer, output_device, fps, scale, speed),
         {:ok, media} <- read_media(rom),
         {:ok, machine} <- Core.load(core, media, Keyword.get(options, :load_options, [])),
         {:ok, components} <-
           start_components(
             core,
             machine,
             framebuffer,
             output_device,
             fps,
             scale,
             speed,
             options
           ) do
      {:ok,
       Map.merge(components, %{
         rom: rom,
         system: core.id,
         runtime_kind: core.runtime,
         capabilities: core.capabilities,
         controls: controls,
         held: empty_controls(core.capabilities.input),
         scale: scale,
         frame: -1,
         renderer_log: ""
       })}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    video = state.capabilities.video

    reply = %{
      rom: state.rom,
      system: state.system,
      frame: state.frame,
      scale: state.scale,
      video: %{
        width: video.width,
        height: video.height,
        scaled_width: video.width * state.scale,
        scaled_height: video.height * state.scale
      },
      audio: audio_status(state.audio),
      controls: Map.new(state.held, fn {port, held} -> {port, MapSet.to_list(held)} end),
      stream: Stream.status(state.stream)
    }

    {:reply, reply, state}
  end

  def handle_call({:key, key, direction, port}, _from, state) when direction in [:down, :up] do
    case button_for(key, state.controls) do
      nil -> {:reply, :ignore, state}
      button -> update_button(state, port, button, direction)
    end
  end

  def handle_call({:key, _key, _direction, _port}, _from, state),
    do: {:reply, :ignore, state}

  def handle_call({:button, button, direction, port}, _from, state)
      when button in @buttons and direction in [:down, :up],
      do: update_button(state, port, button, direction)

  def handle_call({:button, _button, _direction, _port}, _from, state),
    do: {:reply, :ignore, state}

  def handle_call({:set_buttons, port, buttons}, _from, state) do
    if is_list(buttons) and Map.has_key?(state.held, port) and
         Enum.all?(buttons, &supported?(state.capabilities.input, port, &1)) do
      held = MapSet.new(buttons)
      dispatch_input(state, port, held)
      {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
    else
      {:reply, {:error, :invalid_buttons}, state}
    end
  end

  @impl true
  def handle_info({:frame, _number}, %{runtime_kind: :nes} = state), do: render_latest(state)

  def handle_info({:video_frame, system, _number}, %{system: system} = state),
    do: render_latest(state)

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

  def handle_info({:EXIT, pid, reason}, state)
      when pid in [state.runtime, state.stream, state.owned_output],
      do: {:stop, {:child_exit, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_audio(state.audio)
    stop_process(state.stream)
    stop_process(state.runtime)
    stop_renderer(state.renderer)
    stop_process(state.owned_output)
    :ok
  end

  defp render_latest(state) do
    case latest_video(state) do
      %VideoFrame{width: width, height: height} = frame
      when width == state.capabilities.video.width and height == state.capabilities.video.height ->
        case Port.command(state.renderer, Video.rgb_payload(frame)) do
          true -> {:noreply, %{state | frame: frame.number}}
          false -> {:stop, :framebuffer_renderer_closed, state}
        end

      nil ->
        {:noreply, state}

      _frame ->
        {:stop, :invalid_video_frame, state}
    end
  end

  defp latest_video(%{runtime_kind: :nes}), do: NESOutput.latest_video()
  defp latest_video(%{output: output}), do: Output.latest_video(output)

  defp update_button(state, port, button, direction) do
    with {:ok, current} <- Map.fetch(state.held, port),
         true <- supported?(state.capabilities.input, port, button) do
      held =
        if direction == :down,
          do: MapSet.put(current, button),
          else: MapSet.delete(current, button)

      dispatch_input(state, port, held)
      {:reply, :ok, %{state | held: Map.put(state.held, port, held)}}
    else
      _unsupported -> {:reply, :ignore, state}
    end
  end

  defp dispatch_input(%{runtime_kind: :nes, runtime: runtime}, port, held),
    do: NESRuntime.set_buttons(runtime, port, MapSet.to_list(held))

  defp dispatch_input(%{runtime: runtime}, port, held),
    do: Runtime.set_input(runtime, Input.new(port, held))

  defp start_components(core, machine, framebuffer, output_device, fps, scale, speed, options) do
    case start_output(core) do
      {:ok, output, owned_output} ->
        start_with_output(
          core,
          machine,
          output,
          owned_output,
          framebuffer,
          output_device,
          fps,
          scale,
          speed,
          options
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp start_with_output(
         core,
         machine,
         output,
         owned_output,
         framebuffer,
         output_device,
         fps,
         scale,
         speed,
         options
       ) do
    video = core.capabilities.video

    case start_renderer(framebuffer, fps, scale, video) do
      {:ok, renderer} ->
        start_after_renderer(
          core,
          machine,
          output,
          owned_output,
          renderer,
          framebuffer,
          output_device,
          fps,
          scale,
          speed,
          options
        )

      {:error, _reason} = error ->
        stop_process(owned_output)
        error
    end
  end

  defp start_after_renderer(
         core,
         machine,
         output,
         owned_output,
         renderer,
         framebuffer,
         output_device,
         fps,
         scale,
         speed,
         options
       ) do
    case subscribe_video(core, output) do
      :ok ->
        audio = start_audio(options, speed, output, core.capabilities.audio)

        case start_runtime(core, machine, output, speed, options) do
          {:ok, runtime} ->
            start_stream(
              core,
              runtime,
              audio,
              renderer,
              output,
              owned_output,
              framebuffer,
              output_device,
              fps,
              scale
            )

          {:error, reason} ->
            cleanup(audio, nil, renderer, owned_output)
            {:error, reason}
        end

      {:error, reason} ->
        stop_renderer(renderer)
        stop_process(owned_output)
        {:error, reason}
    end
  end

  defp start_stream(
         core,
         runtime,
         audio,
         renderer,
         output,
         owned_output,
         framebuffer,
         output_device,
         fps,
         scale
       ) do
    video = core.capabilities.video

    case Stream.start_link(
           framebuffer: framebuffer,
           output: output_device,
           fps: fps,
           width: video.width * scale,
           height: video.height * scale
         ) do
      {:ok, stream} ->
        {:ok,
         %{
           renderer: renderer,
           runtime: runtime,
           stream: stream,
           output: output,
           owned_output: owned_output,
           audio: audio
         }}

      {:error, reason} ->
        cleanup(audio, runtime, renderer, owned_output)
        {:error, reason}
    end
  end

  defp start_output(%Core{id: :nes}) do
    case Process.whereis(NESOutput) do
      nil -> {:error, :nes_output_unavailable}
      _pid -> {:ok, NESOutput, nil}
    end
  end

  defp start_output(%Core{id: :gbc}) do
    case Output.start_link([]) do
      {:ok, output} -> {:ok, output, output}
      {:error, _reason} = error -> error
    end
  end

  defp subscribe_video(%Core{runtime: :nes}, _output), do: NESOutput.subscribe_video()
  defp subscribe_video(%Core{runtime: :host}, output), do: Output.subscribe_video(output)

  defp start_runtime(%Core{runtime: :nes}, machine, _output, speed, options) do
    NESRuntime.start_link(
      console: machine,
      speed: speed,
      audio_slices: Keyword.get(options, :audio_slices, 2),
      pace: Keyword.get(options, :pace, true),
      name: Keyword.get(options, :runtime_name, BeamicomV4L2.NESRuntime)
    )
  end

  defp start_runtime(
         %Core{runtime: :host, system: Beamicom.GB.System},
         machine,
         output,
         speed,
         options
       ) do
    Runtime.start_link(
      machine: machine,
      output: output,
      speed: speed,
      pace: Keyword.get(options, :pace, true),
      name: Keyword.get(options, :runtime_name)
    )
  end

  defp start_renderer(framebuffer, fps, scale, video) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, "ffmpeg is required to render Beamicom into #{framebuffer}"}

      executable ->
        {:ok,
         Port.open(
           {:spawn_executable, executable},
           [
             :binary,
             :exit_status,
             :use_stdio,
             :stderr_to_stdout,
             args: renderer_args(framebuffer, fps, scale, video)
           ]
         )}
    end
  end

  @doc false
  def renderer_args(framebuffer, fps, scale, %{width: width, height: height}) do
    ~w(-hide_banner -loglevel error -f rawvideo -pixel_format rgb24 -video_size #{width}x#{height}) ++
      ["-framerate", Integer.to_string(fps)] ++
      [
        "-i",
        "pipe:0",
        "-vf",
        "scale=#{width * scale}:#{height * scale}:flags=neighbor",
        "-pix_fmt",
        "bgra",
        "-f",
        "fbdev",
        framebuffer
      ]
  end

  defp start_audio(options, speed, output, capabilities) do
    if Keyword.get(options, :audio, true) do
      audio_options = [speed: speed, output: output, audio: capabilities]

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

  defp cleanup(audio, runtime, renderer, owned_output) do
    stop_audio(audio)
    stop_process(runtime)
    stop_renderer(renderer)
    stop_process(owned_output)
  end

  defp stop_audio(%{pid: pid}), do: stop_process(pid)
  defp stop_audio(_audio), do: :ok

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp stop_process(_pid), do: :ok

  defp stop_renderer(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp stop_renderer(_port), do: :ok

  defp empty_controls(%InputCapabilities{ports: ports}),
    do: Map.new(ports, fn {port, _buttons} -> {port, MapSet.new()} end)

  defp supported?(%InputCapabilities{ports: ports}, port, button) do
    case Map.fetch(ports, port) do
      {:ok, buttons} -> MapSet.member?(buttons, button)
      :error -> false
    end
  end

  defp read_media(path) do
    case File.read(path) do
      {:ok, media} -> {:ok, media}
      {:error, reason} -> {:error, "cannot read ROM #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, "ROM is not a regular file: #{path}"}
      {:error, reason} -> {:error, "cannot read ROM #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp valid_options(framebuffer, output, fps, scale, speed) do
    cond do
      not is_binary(framebuffer) or framebuffer == "" ->
        {:error, {:invalid_option, :framebuffer}}

      not is_binary(output) or output == "" ->
        {:error, {:invalid_option, :output}}

      not is_integer(fps) or fps not in 1..1_000 ->
        {:error, {:invalid_option, :fps}}

      not is_integer(scale) or scale not in 1..8 ->
        {:error, "scale must be an integer from 1 through 8"}

      not is_number(speed) or speed <= 0 ->
        {:error, "speed must be a positive number"}

      true ->
        :ok
    end
  end

  defp name_option(nil), do: []
  defp name_option(name), do: [name: name]

  defp tail(log) when byte_size(log) <= 4_096, do: log
  defp tail(log), do: binary_part(log, byte_size(log) - 4_096, 4_096)
end
