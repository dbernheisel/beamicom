defmodule Beamicom.NES.Scenic.Screen do
  @moduledoc """
  Scenic scene for local verification. It consumes the active core's typed
  video frames, converts its native pixel format to RGB24, scales it with
  nearest-neighbor sampling, and swaps a streamed bitmap.

  Local keyboard is player 1. Debug keys pause/resume and single-step either
  core. NES additionally supports raw palette-address grayscale and share PNGs.

  ## Sources
    * Scenic `Assets.Stream` (hand-built `{Bitmap, {w,h,:rgb}, bin}` tuple) and
      `scenic_driver_local` linear sampling — spec §7.
  """
  use Scenic.Scene

  import Scenic.Primitives, only: [rect: 3, text: 2, text: 3]
  import Scenic.Components, only: [button: 3]
  alias Beamicom.Host.{Output, VideoFrame}
  alias Beamicom.NES.ShareImage
  alias Beamicom.NES.Output, as: NESOutput
  alias Beamicom.Scenic.{Runtime, Video}
  alias Scenic.Assets.Stream
  alias Scenic.Assets.Stream.Bitmap
  alias Scenic.Graph

  @stream "beamicom_screen"

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

  # Height (px) of the control bar below the game screen (holds the Save button
  # and the "saved …" confirmation label). The viewport is sized game-height +
  # this, so the controls never overlap the game.
  @controls_h 76

  @doc "Extra viewport height reserved for the control bar below the screen."
  def controls_height, do: @controls_h
  def controls_height(:nes), do: @controls_h
  def controls_height(:gbc), do: 0

  @impl true
  def init(scene, params, _opts) do
    scale = Keyword.get(params, :scale, 3)
    system = Keyword.fetch!(params, :system)
    runtime_kind = Keyword.fetch!(params, :runtime_kind)
    runtime = Keyword.fetch!(params, :runtime)
    output = Keyword.fetch!(params, :output)
    video = capabilities(system).video
    {w, h} = {video.width * scale, video.height * scale}

    Stream.start_link(nil)
    Stream.put(@stream, {Bitmap, {w, h, :rgb}, :binary.copy(<<0, 0, 0>>, w * h)})
    subscribe_video(runtime_kind, output)

    graph =
      Graph.build()
      |> rect({w, h}, fill: {:stream, @stream})
      |> add_nes_controls(system, w, h)

    scene =
      scene
      |> assign(
        scale: scale,
        system: system,
        runtime_kind: runtime_kind,
        runtime: runtime,
        output: output,
        pressed: MapSet.new(),
        gray: false,
        paused: false,
        graph: graph
      )
      |> push_graph(graph)

    request_input(scene, [:key])
    {:ok, scene}
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

  # A background save finished: show the file name under the Save button.
  def handle_info({:saved, path}, scene) do
    graph = Graph.modify(scene.assigns.graph, :saved_label, &text(&1, "saved #{path}"))
    {:noreply, scene |> assign(graph: graph) |> push_graph(graph)}
  end

  @impl true
  def handle_input({:key, {key, action, _mods}}, _id, scene) when action in [0, 1] do
    {:noreply, key(key, action == 1, scene)}
  end

  def handle_input(_input, _id, scene) do
    {:noreply, scene}
  end

  # The "Save" button snapshots the live console and writes a share PNG.
  @impl true
  def handle_event({:click, :save}, _from, scene) do
    if scene.assigns.system == :nes, do: save_snapshot(scene.assigns.runtime)
    {:noreply, scene}
  end

  def handle_event(_event, _from, scene), do: {:noreply, scene}

  defp save_snapshot(runtime) do
    case Beamicom.NES.Runtime.snapshot(runtime) do
      {console, fb} when not is_nil(fb) ->
        stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
        path = "beamicom-save-#{stamp}.png"

        me = self()

        Task.start(fn ->
          File.write!(path, ShareImage.to_png(console, fb))
          send(me, {:saved, path})
        end)

      _ ->
        IO.puts("no frame rendered yet — nothing to save")
    end
  end

  # Controller keys update the pressed set and push it to player 1.
  defp key(k, down?, scene) when is_map_key(@buttons, k) do
    pressed =
      if down?,
        do: MapSet.put(scene.assigns.pressed, @buttons[k]),
        else: MapSet.delete(scene.assigns.pressed, @buttons[k])

    Beamicom.EI.Client.set_buttons(Beamicom.NES.Scenic.EIClient, 1, MapSet.to_list(pressed))
    assign(scene, pressed: pressed)
  end

  # Debug keys act on key-down only.
  defp key(:key_space, true, scene) do
    runtime_action(scene, if(scene.assigns.paused, do: :resume, else: :pause))
    assign(scene, paused: not scene.assigns.paused)
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

    case latest_video(assigns.runtime_kind, assigns.output) do
      %VideoFrame{} = frame ->
        rgb = Video.rgb_payload(frame, grayscale: assigns.gray)
        {w, h} = {frame.width * assigns.scale, frame.height * assigns.scale}
        pixels = Video.upscale(rgb, frame.width, assigns.scale)
        Stream.put(@stream, {Bitmap, {w, h, :rgb}, pixels})
        {:noreply, scene}

      nil ->
        {:noreply, scene}
    end
  end

  defp latest_video(:nes, _output), do: NESOutput.latest_video()
  defp latest_video(:host, output), do: Output.latest_video(output)

  defp subscribe_video(:nes, _output), do: NESOutput.subscribe_video()
  defp subscribe_video(:host, output), do: Output.subscribe_video(output)

  defp capabilities(:nes), do: Beamicom.NES.System.capabilities()
  defp capabilities(:gbc), do: Beamicom.GB.System.capabilities()

  defp add_nes_controls(graph, :gbc, _width, _height), do: graph

  defp add_nes_controls(graph, :nes, width, height) do
    graph
    |> button("Save",
      id: :save,
      theme: :dark,
      width: 120,
      height: 28,
      t: {div(width - 120, 2), height + 10}
    )
    |> text("",
      id: :saved_label,
      text_align: :center,
      font_size: 16,
      fill: :white,
      t: {div(width, 2), height + 60}
    )
  end

  defp runtime_action(%{assigns: %{runtime_kind: :nes, runtime: runtime}}, action),
    do: apply(Beamicom.NES.Runtime, action, [runtime])

  defp runtime_action(%{assigns: %{runtime_kind: :host, runtime: runtime}}, action),
    do: apply(Runtime, action, [runtime])
end
