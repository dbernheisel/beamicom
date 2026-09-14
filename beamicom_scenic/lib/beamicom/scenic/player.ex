defmodule Beamicom.Scenic.Player do
  @moduledoc false

  use GenServer

  alias Beamicom.Host.{Input, Output, VideoFrame}
  alias Beamicom.GB.ShareImage, as: GBShareImage
  alias Beamicom.NES.{PPU, ShareImage}
  alias Beamicom.NES.Output, as: NESOutput
  alias Beamicom.Scenic.{AudioSink, Core, Runtime, SaveState, Settings}

  def start(options), do: GenServer.start(__MODULE__, options, name: __MODULE__)
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def scene_options(server \\ __MODULE__), do: GenServer.call(server, :scene_options)

  def set_enhancement(server \\ __MODULE__, enhancement, enabled),
    do: GenServer.call(server, {:set_enhancement, enhancement, enabled})

  def set_volume(server \\ __MODULE__, volume),
    do: GenServer.call(server, {:set_volume, volume})

  def prepare_reconfigure(server \\ __MODULE__, options),
    do: GenServer.call(server, {:prepare_reconfigure, options}, :infinity)

  def await_video(server \\ __MODULE__, timeout \\ 10_000),
    do: GenServer.call(server, {:await_video, timeout}, timeout + 1_000)

  def prepare(path, player_options) when is_binary(path) and is_list(player_options) do
    requested_options = player_options

    with {:ok, media} <- File.read(path),
         {:ok, core} <- resolve_core(path, media),
         player_options =
           Settings.player_options(core.id, requested_options, Settings.load_or_defaults()),
         speed = Keyword.get(player_options, :speed, 1.0),
         volume = Keyword.get(player_options, :volume, 100),
         {:ok, load_options, video_filter} <- load_options(core, player_options),
         scale = Keyword.get(player_options, :scale, default_scale(core, video_filter)),
         :ok <- validate_options(scale, speed, volume),
         :ok <- validate_scale(scale, core, video_filter),
         core = configure_core(core, load_options),
         :ok <- warm_core(core),
         {:ok, machine} <- load(core, path, media, load_options),
         rom_hash = SaveState.rom_hash(core.id, machine),
         {machine, lighting} <- configure_nes_lighting(core, machine, player_options, rom_hash) do
      {:ok,
       %{
         path: Path.expand(path),
         options: player_options,
         requested_options: requested_options,
         core: core,
         machine: machine,
         rom_hash: rom_hash,
         scale: scale,
         speed: speed,
         volume: volume,
         video_filter: video_filter,
         lighting: lighting
       }}
    end
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    prepared = Keyword.get(options, :prepared)

    prepared_result =
      if prepared do
        {:ok, prepared}
      else
        prepare(Keyword.fetch!(options, :path), Keyword.fetch!(options, :options))
      end

    with {:ok, prepared} <- prepared_result,
         %{
           core: core,
           machine: machine,
           speed: speed,
           volume: volume,
           options: player_options
         } <- prepared,
         {:ok, output, owned_output} <- start_output(core),
         {:ok, audio} <- start_audio(core, output, speed, player_options),
         {:ok, runtime} <- start_runtime(core, machine, output, speed, player_options),
         {:ok, input_server, input_client} <- start_input(core, self()),
         scene_options =
           scene_options(core, runtime, output, prepared.scale, prepared.video_filter) do
      {:ok,
       %{
         path: prepared.path,
         rom_hash: prepared.rom_hash,
         options: player_options,
         requested_options: prepared.requested_options,
         core: core,
         scale: prepared.scale,
         speed: speed,
         volume: volume,
         video_filter: prepared.video_filter,
         lighting: prepared.lighting,
         output: output,
         owned_output: owned_output,
         audio: audio,
         runtime: runtime,
         input_server: input_server,
         input_client: input_client,
         scene_options: scene_options,
         paused: false,
         controller_buttons: %{}
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
       rom_hash: state.rom_hash,
       system: state.core.id,
       paused: state.paused,
       scale: state.scale,
       speed: state.speed,
       volume: state.volume,
       video_filter: filter_name(state.video_filter),
       lighting: state.lighting,
       video: %{
         width: video.width,
         height: video.height,
         scaled_width: scaled_width,
         scaled_height: scaled_height
       }
     }, state}
  end

  def handle_call(:scene_options, _from, state), do: {:reply, state.scene_options, state}

  def handle_call(
        {:set_enhancement, enhancement, enabled},
        _from,
        %{core: %Core{id: :nes}} = state
      )
      when enhancement in [:hide_horizontal_overscan, :unlimited_sprites] and
             is_boolean(enabled) do
    case Beamicom.NES.Runtime.set_enhancement(state.runtime, enhancement, enabled) do
      :ok ->
        enhancements =
          state.options
          |> Keyword.get(:enhancements, [])
          |> Keyword.put(enhancement, enabled)

        options = Keyword.put(state.options, :enhancements, enhancements)
        requested_options = Keyword.put(state.requested_options, :enhancements, enhancements)

        {:reply, {:ok, requested_options},
         %{state | options: options, requested_options: requested_options}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_enhancement, _enhancement, _enabled}, _from, state),
    do: {:reply, {:error, :unsupported_system}, state}

  def handle_call({:set_volume, volume}, _from, state)
      when is_integer(volume) and volume >= 0 and volume <= 100 do
    :ok = set_audio_volume(state.audio, volume)
    options = Keyword.put(state.options, :volume, volume)
    requested_options = Keyword.put(state.requested_options, :volume, volume)

    {:reply, {:ok, requested_options},
     %{state | volume: volume, options: options, requested_options: requested_options}}
  end

  def handle_call({:set_volume, _volume}, _from, state),
    do: {:reply, {:error, {:invalid_option, :volume}}, state}

  def handle_call({:prepare_reconfigure, overrides}, _from, state)
      when is_list(overrides) do
    requested_options = Keyword.merge(state.requested_options, overrides)

    player_options =
      Settings.player_options(state.core.id, requested_options, Settings.load_or_defaults())

    with speed = Keyword.get(player_options, :speed, 1.0),
         volume = Keyword.get(player_options, :volume, 100),
         {:ok, load_options, video_filter} <- load_options(state.core, player_options),
         scale = Keyword.get(player_options, :scale, default_scale(state.core, video_filter)),
         :ok <- validate_options(scale, speed, volume),
         :ok <- validate_scale(scale, state.core, video_filter),
         core = configure_core(state.core, load_options),
         {:ok, machine} <- snapshot_machine(state, load_options),
         {machine, lighting} <-
           configure_nes_lighting(core, machine, player_options, state.rom_hash) do
      {:reply,
       {:ok,
        %{
          path: state.path,
          options: player_options,
          requested_options: requested_options,
          core: core,
          machine: machine,
          rom_hash: state.rom_hash,
          scale: scale,
          speed: speed,
          volume: volume,
          video_filter: video_filter,
          lighting: lighting
        }}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prepare_reconfigure, _overrides}, _from, state),
    do: {:reply, {:error, {:invalid_option, :reconfigure}}, state}

  def handle_call({:await_video, timeout}, _from, state)
      when is_integer(timeout) and timeout >= 0 do
    video = state.core.capabilities.video
    {:reply, await_video_frame(state, video.width, video.height, timeout), state}
  end

  def handle_call(:snapshot, _from, %{core: %Core{id: :nes}} = state) do
    case Beamicom.NES.Runtime.snapshot(state.runtime) do
      {console, framebuffer} when not is_nil(framebuffer) ->
        {:reply, {:ok, {:nes, console, framebuffer}}, state}

      _snapshot ->
        {:reply, {:error, :no_frame}, state}
    end
  end

  def handle_call(:snapshot, _from, %{core: %Core{id: :gbc}} = state) do
    case Output.latest_video(state.output) do
      %VideoFrame{data: frame} ->
        machine = Runtime.snapshot(state.runtime)
        {:reply, {:ok, {:gbc, machine, frame}}, state}

      nil ->
        {:reply, {:error, :no_frame}, state}
    end
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, {:error, :unsupported_system}, state}

  def handle_call(:pause, _from, %{paused: true} = state), do: {:reply, :ok, state}

  def handle_call(:pause, _from, state) do
    clear_input(state.core, state.runtime)
    :ok = pause_audio(state.audio)
    runtime_action(state.core, state.runtime, :pause)
    {:reply, :ok, %{state | paused: true, controller_buttons: %{}}}
  end

  def handle_call(:resume, _from, %{paused: false} = state), do: {:reply, :ok, state}

  def handle_call(:resume, _from, state) do
    :ok = resume_audio(state.audio)
    runtime_action(state.core, state.runtime, :resume)
    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_cast({:controller_input, port, buttons}, state) do
    buttons = MapSet.new(buttons)
    previous = Map.get(state.controller_buttons, port, MapSet.new())

    if state.paused do
      buttons
      |> MapSet.difference(previous)
      |> Enum.each(&send(Beamicom.Scenic.Host, {:controller_menu, &1}))
    else
      dispatch_input(state.core, state.runtime, port, MapSet.to_list(buttons))
    end

    {:noreply, %{state | controller_buttons: Map.put(state.controller_buttons, port, buttons)}}
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
      state.input_client
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

  defp validate_options(scale, speed, volume) do
    cond do
      not is_number(scale) or scale < 1 ->
        {:error, {:invalid_option, :scale}}

      not is_number(speed) or speed <= 0 ->
        {:error, {:invalid_option, :speed}}

      not is_integer(volume) or volume < 0 or volume > 100 ->
        {:error, {:invalid_option, :volume}}

      true ->
        :ok
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

  defp load(%Core{id: :gbc}, path, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png, _options) do
    case GBShareImage.load_image(png, [Path.dirname(path)]) do
      {:ok, machine} -> {:ok, machine}
      {:error, reason} -> {:error, {:save_load_failed, reason}}
    end
  end

  defp load(%Core{} = core, _path, media, load_options), do: Core.load(core, media, load_options)

  defp resolve_core(path, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png) do
    case GBShareImage.classify(png) do
      :gb ->
        system = Beamicom.GB.System

        {:ok,
         %Core{
           id: system.id(),
           system: system,
           runtime: :host,
           capabilities: system.capabilities()
         }}

      _not_gb ->
        Core.resolve(path, png)
    end
  end

  defp resolve_core(path, media), do: Core.resolve(path, media)

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

  defp load_options(%Core{id: :snes}, options) do
    load_options = Keyword.get(options, :load_options, [])

    with :ok <- validate_keyword(load_options, :load_options) do
      {:ok, load_options, nil}
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

  defp configure_nes_lighting(
         %Core{id: :nes},
         console,
         player_options,
         rom_hash
       ) do
    if Keyword.get(player_options, :nes_lighting, false) do
      with true <- Code.ensure_loaded?(Beamicom.NES.Nx.Lighting),
           {:ok, profile} <- Beamicom.NES.Nx.Lighting.for_hash(rom_hash),
           %{renderer: renderer, renderer_options: renderer_options}
           when renderer != :native <- console.bus.ppu do
        renderer = {renderer, Keyword.put(renderer_options, :lighting, profile)}
        console = put_in(console.bus.ppu, PPU.set_renderer(console.bus.ppu, renderer))
        {console, true}
      else
        _unsupported_or_native -> {console, false}
      end
    else
      {console, false}
    end
  end

  defp configure_nes_lighting(%Core{}, machine, _player_options, _rom_hash),
    do: {machine, false}

  defp configure_saved_console(console, load_options) do
    case Keyword.fetch(load_options, :ppu_renderer) do
      {:ok, renderer} -> put_in(console.bus.ppu, PPU.set_renderer(console.bus.ppu, renderer))
      :error -> console
    end
  end

  defp snapshot_machine(%{core: %Core{id: :nes}, runtime: runtime}, load_options) do
    case Beamicom.NES.Runtime.snapshot(runtime) do
      {console, _framebuffer} -> {:ok, reconfigure_console(console, load_options)}
      _snapshot -> {:error, :snapshot_failed}
    end
  end

  defp snapshot_machine(%{core: %Core{id: :gbc}, runtime: runtime}, _load_options),
    do: {:ok, Runtime.snapshot(runtime)}

  defp reconfigure_console(console, load_options) do
    renderer = Keyword.get(load_options, :ppu_renderer, PPU.configured_renderer())
    put_in(console.bus.ppu, PPU.set_renderer(console.bus.ppu, renderer))
  end

  defp await_video_frame(state, width, height, timeout) do
    started_at = System.monotonic_time(:millisecond)
    do_await_video_frame(state, width, height, timeout, started_at)
  end

  defp do_await_video_frame(state, width, height, timeout, started_at) do
    case latest_video(state) do
      %VideoFrame{width: ^width, height: ^height} ->
        :ok

      _frame ->
        if System.monotonic_time(:millisecond) - started_at >= timeout do
          {:error, :video_timeout}
        else
          Process.sleep(2)
          do_await_video_frame(state, width, height, timeout, started_at)
        end
    end
  end

  defp latest_video(%{core: %Core{id: :nes}}), do: NESOutput.latest_video()
  defp latest_video(%{output: output}), do: Output.latest_video(output)

  defp start_output(%Core{id: :nes}) do
    case Process.whereis(NESOutput) do
      nil -> {:error, :nes_output_unavailable}
      _pid -> {:ok, NESOutput, nil}
    end
  end

  defp start_output(%Core{runtime: :host}) do
    case Output.start_link([]) do
      {:ok, output} -> {:ok, output, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_audio(core, output, speed, options) do
    if Keyword.get(options, :audio, true) do
      audio_options = [
        output: output,
        audio: core.capabilities.audio,
        speed: speed,
        volume: Keyword.get(options, :volume, 100),
        prebuffer_ms: Keyword.get(options, :audio_prebuffer_ms, 250)
      ]

      audio_options =
        case Keyword.fetch(options, :audio_command) do
          {:ok, command} -> Keyword.put(audio_options, :command, command)
          :error -> audio_options
        end

      case AudioSink.start_link(audio_options) do
        {:ok, pid} -> {:ok, pid}
        :ignore -> {:ok, nil}
        {:error, reason} -> {:error, {:audio_start_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp warm_core(%Core{id: :snes}) do
    if Application.get_env(:beamicom_snes, :ppu_renderer, :native) == :nx and
         Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      Beamicom.SNES.Nx.PPURenderer.warmup()
    else
      :ok
    end
  end

  defp warm_core(%Core{}), do: :ok

  defp pause_audio(nil), do: :ok
  defp pause_audio(audio), do: AudioSink.pause(audio)

  defp resume_audio(nil), do: :ok
  defp resume_audio(audio), do: AudioSink.resume(audio)

  defp set_audio_volume(nil, _volume), do: :ok
  defp set_audio_volume(audio, volume), do: AudioSink.set_volume(audio, volume)

  defp start_runtime(%Core{runtime: :nes}, machine, _output, speed, options) do
    Beamicom.NES.Runtime.start_link(
      console: machine,
      speed: speed,
      pace: Keyword.get(options, :pace, true),
      audio_slices: Keyword.get(options, :audio_slices, 1),
      enhancements: Keyword.get(options, :enhancements, []),
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

  defp start_input(core, owner) do
    socket = Beamicom.EI.default_path()
    ports = core.capabilities.input.ports |> Map.keys() |> Enum.sort()
    callback = fn port, buttons -> GenServer.cast(owner, {:controller_input, port, buttons}) end

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

  defp clear_input(core, runtime) do
    core.capabilities.input.ports
    |> Map.keys()
    |> Enum.each(&dispatch_input(core, runtime, &1, []))
  end

  defp runtime_action(%Core{runtime: :nes}, runtime, :pause),
    do: Beamicom.NES.Runtime.pause(runtime)

  defp runtime_action(%Core{runtime: :nes}, runtime, :resume),
    do: Beamicom.NES.Runtime.resume(runtime)

  defp runtime_action(%Core{runtime: :host}, runtime, :pause), do: Runtime.pause(runtime)
  defp runtime_action(%Core{runtime: :host}, runtime, :resume), do: Runtime.resume(runtime)

  defp scene_options(core, runtime, output, scale, video_filter) do
    video = core.capabilities.video
    {width, height} = scaled_dimensions(video, scale)

    [
      scale: scale,
      system: core.id,
      runtime_kind: core.runtime,
      runtime: runtime,
      output: output,
      video: video,
      output_size: {width, height},
      video_filter: video_filter
    ]
  end

  defp scaled_dimensions(video, scale) do
    {pixel_x, pixel_y} = Map.get(video, :pixel_scale, {1, 1})
    {round(video.width * pixel_x * scale), round(video.height * pixel_y * scale)}
  end
end
