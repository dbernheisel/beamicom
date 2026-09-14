defmodule Beamicom.Scenic.Component.GameSurface do
  @moduledoc """
  Scenic scene for local verification. It consumes the active core's typed
  video frames, converts its native pixel format to RGB24, applies the selected
  presentation scaler, and swaps a streamed bitmap.

  Local keyboard is player 1. Debug keys pause/resume and single-step either
  core. NES additionally supports raw palette-address grayscale and share PNGs.

  ## Sources

    * Scenic `Assets.Stream` (hand-built `{Bitmap, {w,h,:rgb}, bin}` tuple) — spec §7.
  """
  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [rect: 3]
  alias Beamicom.Host.{Output, VideoFrame}
  alias Beamicom.NES.Output, as: NESOutput
  alias Beamicom.Scenic.{Runtime, Video}
  alias Scenic.Assets.Stream
  alias Scenic.Assets.Stream.Bitmap
  alias Scenic.Graph

  # Player-1 key → button.
  @buttons %{
    key_up: :up,
    key_down: :down,
    key_left: :left,
    key_right: :right,
    key_x: :a,
    key_z: :b,
    key_enter: :start,
    key_rightshift: :select
  }

  @impl Scenic.Component
  def validate(params) when is_list(params) do
    required = [:system, :runtime_kind, :runtime, :output, :video, :output_size]

    if Enum.all?(required, &Keyword.has_key?(params, &1)),
      do: {:ok, params},
      else: {:error, "game surface is missing required session options"}
  end

  def validate(params), do: {:error, "expected game surface options, got: #{inspect(params)}"}

  @impl Scenic.Component
  def bounds(params, _styles) do
    {width, height} = Keyword.fetch!(params, :output_size)
    {0, 0, width, height}
  end

  @impl true
  def init(scene, params, _opts) do
    scale = Keyword.get(params, :scale, 3)
    system = Keyword.fetch!(params, :system)
    runtime_kind = Keyword.fetch!(params, :runtime_kind)
    runtime = Keyword.fetch!(params, :runtime)
    output = Keyword.fetch!(params, :output)
    video_filter = Keyword.get(params, :video_filter)
    video = Keyword.get_lazy(params, :video, fn -> capabilities(system).video end)
    {pixel_x, pixel_y} = Map.get(video, :pixel_scale, {1, 1})

    {w, h} =
      Keyword.get_lazy(params, :output_size, fn ->
        {round(video.width * scale * pixel_x), round(video.height * scale * pixel_y)}
      end)

    Stream.start_link(nil)
    stream = "beamicom_screen_#{System.unique_integer([:positive])}"
    ensure_stream(stream, {w, h})
    subscribe_video(runtime_kind, output)

    styles =
      if Keyword.get(params, :border?, true),
        do: [fill: {:stream, stream}, stroke: {2, {105, 213, 255}}],
        else: [fill: {:stream, stream}]

    graph = Graph.build() |> rect({w, h}, styles)

    scene =
      scene
      |> assign(
        scale: scale,
        output_size: {w, h},
        system: system,
        runtime_kind: runtime_kind,
        runtime: runtime,
        output: output,
        video_filter: video_filter,
        native_size: {video.width, video.height},
        pressed: MapSet.new(),
        gray: false,
        paused: false,
        stream: stream,
        fps_started_at: now_ms(),
        fps_frames: 0,
        graph: graph
      )
      |> push_graph(graph)

    scene = render_latest_scene(scene)

    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_update(params, opts, scene) do
    Stream.delete(scene.assigns.stream)
    init(scene, params, opts)
  end

  @impl true
  def terminate(_reason, scene) do
    if stream = scene.assigns[:stream], do: Stream.delete(stream)
    :ok
  end

  @impl true
  def handle_info({:frame, _number}, %{assigns: %{runtime_kind: :nes}} = scene),
    do: render_latest(scene)

  def handle_info(
        {:video_frame, system, _number},
        %{assigns: %{system: system, runtime_kind: :host}} = scene
      ),
      do: render_latest(scene)

  # Audio arrives here too (see Output); the Scenic sink is video-only.
  def handle_info({:audio, _sample_count, _pcm}, scene), do: {:noreply, scene}
  def handle_info({:audio_chunk, _chunk}, scene), do: {:noreply, scene}

  @impl Scenic.Scene
  def handle_put({:key, key, down?}, scene) when is_boolean(down?),
    do: {:noreply, key(key, down?, scene)}

  def handle_put(:reset_fps, scene),
    do: {:noreply, assign(scene, fps_started_at: now_ms(), fps_frames: 0)}

  # Controller keys update the pressed set and push it to player 1.
  defp key(k, down?, scene) when is_map_key(@buttons, k) do
    pressed =
      if down?,
        do: MapSet.put(scene.assigns.pressed, @buttons[k]),
        else: MapSet.delete(scene.assigns.pressed, @buttons[k])

    Beamicom.EI.Client.set_buttons(Beamicom.Scenic.EIClient, 1, MapSet.to_list(pressed))
    assign(scene, pressed: pressed)
  end

  defp key(:key_period, true, scene) do
    runtime_action(scene, :step)
    scene
  end

  defp key(:key_g, true, %{assigns: %{system: :nes}} = scene),
    do: assign(scene, gray: not scene.assigns.gray)

  defp key(_k, _down?, scene), do: scene

  defp render_latest(scene) do
    assigns = scene.assigns

    case safe_latest_video(assigns.runtime_kind, assigns.output) do
      %VideoFrame{width: width, height: height} = frame
      when {width, height} == scene.assigns.native_size ->
        rgb = Video.rgb_payload(frame, grayscale: assigns.gray)
        {w, h} = assigns.output_size

        pixels =
          Video.resize(
            rgb,
            {frame.width, frame.height},
            {w, h},
            assigns.video_filter
          )

        Stream.put(assigns.stream, {Bitmap, {w, h, :rgb}, pixels})
        {:noreply, record_frame(scene)}

      nil ->
        {:noreply, scene}

      _incompatible_frame ->
        {:noreply, scene}
    end
  end

  defp safe_latest_video(runtime_kind, output) do
    latest_video(runtime_kind, output)
  catch
    :exit, _reason -> nil
  end

  defp render_latest_scene(scene) do
    case render_latest(scene) do
      {:noreply, scene} -> scene
    end
  end

  defp latest_video(:nes, _output), do: NESOutput.latest_video()
  defp latest_video(:host, output), do: Output.latest_video(output)

  defp subscribe_video(:nes, _output), do: safe_subscribe(&NESOutput.subscribe_video/0)

  defp subscribe_video(:host, output),
    do: safe_subscribe(fn -> Output.subscribe_video(output) end)

  defp safe_subscribe(subscribe) do
    subscribe.()
  catch
    :exit, _reason -> :ok
  end

  defp ensure_stream(stream, {w, h}) do
    case Stream.fetch(stream) do
      {:ok, {Bitmap, {^w, ^h, :rgb}, _pixels}} ->
        :ok

      _other ->
        Stream.put(stream, {Bitmap, {w, h, :rgb}, :binary.copy(<<0, 0, 0>>, w * h)})
    end
  end

  defp record_frame(scene) do
    frames = scene.assigns.fps_frames + 1
    elapsed = now_ms() - scene.assigns.fps_started_at

    if elapsed >= 1_000 do
      send_parent_event(scene, {:render_fps, frames * 1_000 / elapsed})
      assign(scene, fps_started_at: now_ms(), fps_frames: 0)
    else
      assign(scene, fps_frames: frames)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp capabilities(:nes), do: Beamicom.NES.System.capabilities()
  defp capabilities(:gbc), do: Beamicom.GB.System.capabilities()
  defp capabilities(:snes), do: Beamicom.Scenic.SNESSystem.capabilities()

  defp runtime_action(%{assigns: %{runtime_kind: :nes, runtime: runtime}}, action),
    do: apply(Beamicom.NES.Runtime, action, [runtime])

  defp runtime_action(%{assigns: %{runtime_kind: :host, runtime: runtime}}, action),
    do: apply(Runtime, action, [runtime])
end

defmodule Beamicom.Scenic.Screen do
  @moduledoc "Compatibility root scene backed by the shell game-surface component."

  use Scenic.Scene

  alias Beamicom.Scenic.Component.GameSurface

  def controls_height, do: 0
  def controls_height(_system), do: 0

  @impl Scenic.Scene
  def init(scene, params, opts), do: GameSurface.init(scene, params, opts)

  @impl Scenic.Scene
  def handle_update(params, opts, scene), do: GameSurface.handle_update(params, opts, scene)

  @impl true
  def handle_info(message, scene), do: GameSurface.handle_info(message, scene)

  @impl Scenic.Scene
  def handle_input({:key, {key, action, _mods}}, _id, scene) when action in [0, 1],
    do: GameSurface.handle_put({:key, key, action == 1}, scene)

  def handle_input(_input, _id, scene), do: {:noreply, scene}

  @impl Scenic.Scene
  def handle_event(_event, _from, scene), do: {:noreply, scene}

  @impl true
  def terminate(reason, scene), do: GameSurface.terminate(reason, scene)
end
