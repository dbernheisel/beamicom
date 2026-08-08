defmodule Beamicom.NES.Scenic.Screen do
  @moduledoc """
  Scenic scene for local verification (spec §7). Draws a single rect filled by a
  streamed bitmap; on each `Beamicom.NES.Output` `{:frame, _}` notification it reads the
  latest frame, expands it through `Beamicom.NES.Palette` at integer scale (nearest-
  neighbor, since the driver samples linearly), and swaps the stream — the scene
  graph is static, only the buffer changes.

  Local keyboard is player 1. Debug keys: space pauses/resumes, `.` steps one
  frame while paused, `g` toggles the raw palette-address grayscale view. A
  "Save" button writes a share PNG of the live state (see `Beamicom.NES.ShareImage`).

  ## Sources
    * Scenic `Assets.Stream` (hand-built `{Bitmap, {w,h,:rgb}, bin}` tuple) and
      `scenic_driver_local` linear sampling — spec §7.
  """
  use Scenic.Scene

  import Scenic.Primitives, only: [rect: 3, text: 2, text: 3]
  import Scenic.Components, only: [button: 3]
  alias Beamicom.NES.{Output, Palette, Runtime, ShareImage}
  alias Scenic.Assets.Stream
  alias Scenic.Assets.Stream.Bitmap
  alias Scenic.Graph

  @stream "nes_screen"

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

  @impl true
  def init(scene, params, _opts) do
    scale = Keyword.get(params, :scale, 3)
    {w, h} = {256 * scale, 240 * scale}

    Stream.start_link(nil)
    Stream.put(@stream, {Bitmap, {w, h, :rgb}, :binary.copy(<<0, 0, 0>>, w * h)})
    Output.subscribe_video()

    graph =
      Graph.build()
      |> rect({w, h}, fill: {:stream, @stream})
      |> button("Save",
        id: :save,
        theme: :dark,
        width: 120,
        height: 28,
        t: {div(w - 120, 2), h + 10}
      )
      |> text("",
        id: :saved_label,
        text_align: :center,
        font_size: 16,
        fill: :white,
        t: {div(w, 2), h + 60}
      )

    scene =
      scene
      |> assign(scale: scale, pressed: MapSet.new(), gray: false, paused: false, graph: graph)
      |> push_graph(graph)

    request_input(scene, [:key])
    {:ok, scene}
  end

  @impl true
  def handle_info({:frame, _n}, scene) do
    a = scene.assigns

    case Output.latest() do
      nil ->
        :ok

      fb ->
        native = if a.gray, do: Palette.to_addr_gray(fb), else: Palette.to_rgb(fb)
        {w, h} = {fb.width * a.scale, fb.height * a.scale}
        Stream.put(@stream, {Bitmap, {w, h, :rgb}, upscale(native, fb.width, a.scale)})
    end

    {:noreply, scene}
  end

  # Audio arrives here too (see Output); the Scenic sink is video-only.
  def handle_info({:audio, _sample_count, _pcm}, scene), do: {:noreply, scene}

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
    save_snapshot()
    {:noreply, scene}
  end

  def handle_event(_event, _from, scene), do: {:noreply, scene}

  defp save_snapshot do
    case Runtime.snapshot() do
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

  # Integer nearest-neighbor upscale: the local driver samples textures linearly,
  # so we pre-scale in the bitmap (spec §7) — repeat each pixel's 3 bytes n× per
  # row, then each row n×. This is a driver concern, so it lives in the sink.
  defp upscale(rgb, _width, 1), do: rgb

  defp upscale(rgb, width, n) do
    scaled_row = width * 3 * n
    rows = for <<px::binary-size(3) <- rgb>>, into: <<>>, do: :binary.copy(px, n)
    for <<row::binary-size(^scaled_row) <- rows>>, into: <<>>, do: :binary.copy(row, n)
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
    if scene.assigns.paused, do: Runtime.resume(), else: Runtime.pause()
    assign(scene, paused: not scene.assigns.paused)
  end

  defp key(:key_period, true, scene) do
    Runtime.step()
    scene
  end

  defp key(:key_g, true, scene), do: assign(scene, gray: not scene.assigns.gray)
  defp key(_k, _down?, scene), do: scene
end
