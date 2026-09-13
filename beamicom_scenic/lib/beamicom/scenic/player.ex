defmodule Beamicom.Scenic.Player do
  @moduledoc false

  use GenServer

  alias Beamicom.Host.{Input, Output}
  alias Beamicom.NES.{PPU, ShareImage}
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
    speed = Keyword.get(player_options, :speed, 1.0)

    with {:ok, media} <- File.read(path),
         {:ok, core} <- Core.resolve(path, media),
         {:ok, load_options, video_filter} <- load_options(core, player_options),
         scale = Keyword.get(player_options, :scale, default_scale(core, video_filter)),
         :ok <- validate_options(scale, speed),
         :ok <- validate_scale(scale, core, video_filter),
         core = configure_core(core, load_options),
         {:ok, machine} <- load(core, path, media, load_options),
         {:ok, output, owned_output} <- start_output(core),
         {:ok, audio} <- start_audio(core, output, speed, player_options),
         {:ok, runtime} <- start_runtime(core, machine, output, speed, player_options),
         {:ok, input_server, input_client} <- start_input(core, runtime),
         {:ok, scenic} <- start_scenic(core, runtime, output, scale, video_filter) do
      {:ok,
       %{
         path: Path.expand(path),
         core: core,
         scale: scale,
         speed: speed,
         video_filter: video_filter,
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
    {scaled_width, scaled_height} = scaled_dimensions(video, state.scale)

    {:reply,
     %{
       path: state.path,
       system: state.core.id,
       scale: state.scale,
       speed: state.speed,
       video_filter: filter_name(state.video_filter),
       video: %{
         width: video.width,
         height: video.height,
         scaled_width: scaled_width,
         scaled_height: scaled_height
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
      not is_number(scale) or scale < 1 -> {:error, {:invalid_option, :scale}}
      not is_number(speed) or speed <= 0 -> {:error, {:invalid_option, :speed}}
      true -> :ok
    end
  end

  defp validate_scale(scale, %Core{id: :gbc}, {:pixel_transparency, _options})
       when is_number(scale) and scale >= 1,
       do: :ok

  defp validate_scale(scale, %Core{}, _video_filter) when is_integer(scale) and scale >= 1,
    do: :ok

  defp validate_scale(_scale, %Core{}, _video_filter), do: {:error, {:invalid_option, :scale}}

  defp default_scale(%Core{id: :nes}, filter)
       when filter in [:composite, :svideo, :rgb, :monochrome],
       do: 1

  defp default_scale(%Core{}, _filter), do: 3

  defp load(%Core{id: :nes} = core, path, media, load_options) do
    case media do
      <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png ->
        case ShareImage.load_image(png, [Path.dirname(path)]) do
          {:ok, console} -> {:ok, configure_saved_console(console, load_options)}
          {:error, reason} -> {:error, {:save_load_failed, reason}}
        end

      _media ->
        Core.load(core, media, load_options)
    end
  end

  defp load(%Core{} = core, _path, media, load_options), do: Core.load(core, media, load_options)

  defp load_options(%Core{id: :nes}, options) do
    base = Keyword.get(options, :load_options, [])
    filter_options = Keyword.get(options, :video_filter_options, [])

    with :ok <- validate_keyword(base, :load_options),
         :ok <- validate_keyword(filter_options, :video_filter_options),
         {:ok, filter} <- nes_video_filter(options) do
      case filter do
        nil ->
          {:ok, base, nil}

        :native ->
          {:ok, Keyword.put(base, :ppu_renderer, :native), :native}

        preset ->
          {:ok, Keyword.merge(base, Beamicom.NES.Nx.video_options(preset, filter_options)),
           preset}
      end
    end
  end

  defp load_options(%Core{id: :gbc}, options) do
    load_options = Keyword.get(options, :load_options, [])
    filter_options = Keyword.get(options, :video_filter_options, [])

    with :ok <- validate_keyword(load_options, :load_options),
         :ok <- validate_keyword(filter_options, :video_filter_options),
         {:ok, filter} <- gbc_video_filter(options) do
      filter = if filter == :pixel_transparency, do: {filter, filter_options}, else: filter
      {:ok, load_options, filter}
    end
  end

  defp validate_keyword(value, option) do
    if Keyword.keyword?(value), do: :ok, else: {:error, {:invalid_option, option}}
  end

  defp nes_video_filter(options) do
    filter =
      case Keyword.fetch(options, :video_filter) do
        {:ok, filter} -> filter
        :error -> nes_filter_from_env(System.get_env("BEAMICOM_NES_VIDEO_FILTER"))
      end

    if filter in [nil, :native, :composite, :svideo, :rgb, :monochrome],
      do: {:ok, filter},
      else: {:error, {:invalid_option, :video_filter}}
  end

  defp gbc_video_filter(options) do
    filter =
      case Keyword.fetch(options, :video_filter) do
        {:ok, filter} -> filter
        :error -> gbc_filter_from_env(System.get_env("BEAMICOM_GBC_VIDEO_FILTER"))
      end

    if filter in [nil, :native, :pixel_transparency],
      do: {:ok, filter},
      else: {:error, {:invalid_option, :video_filter}}
  end

  defp nes_filter_from_env(nil), do: nil
  defp nes_filter_from_env(""), do: nil
  defp nes_filter_from_env("native"), do: :native
  defp nes_filter_from_env("composite"), do: :composite
  defp nes_filter_from_env("svideo"), do: :svideo
  defp nes_filter_from_env("rgb"), do: :rgb
  defp nes_filter_from_env("monochrome"), do: :monochrome
  defp nes_filter_from_env(value), do: value

  defp gbc_filter_from_env(nil), do: nil
  defp gbc_filter_from_env(""), do: nil
  defp gbc_filter_from_env("native"), do: :native
  defp gbc_filter_from_env("pixel_transparency"), do: :pixel_transparency
  defp gbc_filter_from_env(value), do: value

  defp filter_name({name, _options}), do: name
  defp filter_name(name), do: name

  defp configure_core(%Core{id: :nes, system: system} = core, load_options),
    do: %{core | capabilities: system.capabilities(load_options)}

  defp configure_core(%Core{} = core, _load_options), do: core

  defp configure_saved_console(console, load_options) do
    case Keyword.fetch(load_options, :ppu_renderer) do
      {:ok, renderer} -> put_in(console.bus.ppu, PPU.set_renderer(console.bus.ppu, renderer))
      :error -> console
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

      case Beamicom.Scenic.AudioSink.start_link(audio_options) do
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
      audio_slices: Keyword.get(options, :audio_slices, 1),
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
             name: Beamicom.Scenic.EIServer,
             path: socket,
             ports: ports,
             on_buttons: callback
           ),
         {:ok, client} <-
           Beamicom.EI.Client.start_link(
             registered_name: Beamicom.Scenic.EIClient,
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

  defp start_scenic(core, runtime, output, scale, video_filter) do
    video = core.capabilities.video
    {width, height} = scaled_dimensions(video, scale)
    controls_height = Beamicom.Scenic.Screen.controls_height(core.id)

    scene_options = [
      scale: scale,
      system: core.id,
      runtime_kind: core.runtime,
      runtime: runtime,
      output: output,
      video: video,
      output_size: {width, height},
      video_filter: video_filter
    ]

    config =
      Application.get_env(:beamicom_scenic, :viewport)
      |> Keyword.put(:size, {width, height + controls_height})
      |> Keyword.put(:default_scene, {Beamicom.Scenic.Screen, scene_options})

    Scenic.start_link([config])
  end

  defp scaled_dimensions(video, scale) do
    {pixel_x, pixel_y} = Map.get(video, :pixel_scale, {1, 1})
    {round(video.width * pixel_x * scale), round(video.height * pixel_y * scale)}
  end
end
