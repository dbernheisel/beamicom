defmodule Beamicom.Scenic.Player do
  @moduledoc false

  use GenServer

  alias Beamicom.Host.{Input, Output}
  alias Beamicom.NES.ShareImage
  alias Beamicom.NES.Output, as: NESOutput
  alias Beamicom.Scenic.{Core, Runtime}

  def start(options), do: GenServer.start(__MODULE__, options, name: __MODULE__)
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(options, :path)
    player_options = Keyword.fetch!(options, :options)
    scale = Keyword.get(player_options, :scale, 3)
    speed = Keyword.get(player_options, :speed, 1.0)

    with :ok <- validate_options(scale, speed),
         {:ok, media} <- File.read(path),
         {:ok, core} <- Core.resolve(path, media),
         {:ok, machine} <-
           load(core, path, media, Keyword.get(player_options, :load_options, [])),
         {:ok, output, owned_output} <- start_output(core),
         {:ok, audio} <- start_audio(core, output, speed, player_options),
         {:ok, runtime} <- start_runtime(core, machine, output, speed, player_options),
         {:ok, input_server, input_client} <- start_input(core, runtime),
         {:ok, scenic} <- start_scenic(core, runtime, output, scale) do
      {:ok,
       %{
         path: Path.expand(path),
         core: core,
         scale: scale,
         speed: speed,
         output: output,
         owned_output: owned_output,
         audio: audio,
         runtime: runtime,
         input_server: input_server,
         input_client: input_client,
         scenic: scenic
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    video = state.core.capabilities.video

    {:reply,
     %{
       path: state.path,
       system: state.core.id,
       scale: state.scale,
       speed: state.speed,
       video: %{
         width: video.width,
         height: video.height,
         scaled_width: video.width * state.scale,
         scaled_height: video.height * state.scale
       }
     }, state}
  end

  @impl true
  def handle_info({:EXIT, audio, _reason}, %{audio: audio} = state) when is_pid(audio),
    do: {:noreply, %{state | audio: nil}}

  def handle_info({:EXIT, child, reason}, state) when reason in [:normal, :shutdown] do
    if child in children(state),
      do: {:stop, {:child_exit, reason}, state},
      else: {:noreply, state}
  end

  def handle_info({:EXIT, child, reason}, state) do
    if child in children(state),
      do: {:stop, {:child_exit, reason}, state},
      else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state
    |> children()
    |> Enum.reverse()
    |> Enum.each(&stop_child/1)

    :ok
  end

  defp children(state) do
    [
      state.owned_output,
      state.audio,
      state.runtime,
      state.input_server,
      state.input_client,
      state.scenic
    ]
    |> Enum.filter(&is_pid/1)
  end

  defp stop_child(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp validate_options(scale, speed) do
    cond do
      not is_integer(scale) or scale < 1 -> {:error, {:invalid_option, :scale}}
      not is_number(speed) or speed <= 0 -> {:error, {:invalid_option, :speed}}
      true -> :ok
    end
  end

  defp load(%Core{id: :nes} = core, path, media, load_options) do
    case media do
      <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png ->
        case ShareImage.load_image(png, [Path.dirname(path)]) do
          {:ok, console} -> {:ok, console}
          {:error, reason} -> {:error, {:save_load_failed, reason}}
        end

      _media ->
        Core.load(core, media, load_options)
    end
  end

  defp load(%Core{} = core, _path, media, load_options), do: Core.load(core, media, load_options)

  defp start_output(%Core{id: :nes}) do
    case Process.whereis(NESOutput) do
      nil -> {:error, :nes_output_unavailable}
      _pid -> {:ok, NESOutput, nil}
    end
  end

  defp start_output(%Core{id: :gbc}) do
    case Output.start_link([]) do
      {:ok, output} -> {:ok, output, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_audio(core, output, speed, options) do
    if Keyword.get(options, :audio, true) do
      audio_options = [output: output, audio: core.capabilities.audio, speed: speed]

      audio_options =
        case Keyword.fetch(options, :audio_command) do
          {:ok, command} -> Keyword.put(audio_options, :command, command)
          :error -> audio_options
        end

      case Beamicom.NES.AudioSink.start_link(audio_options) do
        {:ok, pid} -> {:ok, pid}
        :ignore -> {:ok, nil}
        {:error, reason} -> {:error, {:audio_start_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp start_runtime(%Core{runtime: :nes}, machine, _output, speed, options) do
    Beamicom.NES.Runtime.start_link(
      console: machine,
      speed: speed,
      pace: Keyword.get(options, :pace, true),
      audio_slices: Keyword.get(options, :audio_slices, 2),
      name: Keyword.get(options, :runtime_name, Beamicom.NES.Runtime)
    )
  end

  defp start_runtime(%Core{runtime: :host, system: system}, machine, output, speed, options) do
    Runtime.start_link(
      system: system,
      machine: machine,
      output: output,
      speed: speed,
      pace: Keyword.get(options, :pace, true),
      name: Keyword.get(options, :runtime_name)
    )
  end

  defp start_input(core, runtime) do
    socket = Beamicom.EI.default_path()
    ports = core.capabilities.input.ports |> Map.keys() |> Enum.sort()
    callback = fn port, buttons -> dispatch_input(core, runtime, port, buttons) end

    with {:ok, server} <-
           Beamicom.EI.Server.start_link(
             name: Beamicom.NES.Scenic.EIServer,
             path: socket,
             ports: ports,
             on_buttons: callback
           ),
         {:ok, client} <-
           Beamicom.EI.Client.start_link(
             registered_name: Beamicom.NES.Scenic.EIClient,
             name: "beamicom-scenic",
             path: socket,
             ports: ports
           ),
         :ok <- Beamicom.EI.Client.await_ready(client) do
      {:ok, server, client}
    end
  end

  defp dispatch_input(%Core{runtime: :nes}, runtime, port, buttons),
    do: Beamicom.NES.Runtime.set_buttons(runtime, port, buttons)

  defp dispatch_input(%Core{runtime: :host}, runtime, port, buttons),
    do: Runtime.set_input(runtime, Input.new(port, buttons))

  defp start_scenic(core, runtime, output, scale) do
    video = core.capabilities.video
    controls_height = Beamicom.NES.Scenic.Screen.controls_height(core.id)

    scene_options = [
      scale: scale,
      system: core.id,
      runtime_kind: core.runtime,
      runtime: runtime,
      output: output
    ]

    config =
      Application.get_env(:beamicom_scenic, :viewport)
      |> Keyword.put(:size, {video.width * scale, video.height * scale + controls_height})
      |> Keyword.put(:default_scene, {Beamicom.NES.Scenic.Screen, scene_options})

    Scenic.start_link([config])
  end
end
