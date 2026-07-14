defmodule Beamicom.NES.Scenic.Screen do
  @moduledoc """
  Scenic scene for local verification (spec §7). Draws a single rect filled by a
  streamed bitmap; on each `Beamicom.NES.Output` `{:frame, _}` notification it reads the
  latest frame, expands it through `Beamicom.NES.Palette` at integer scale (nearest-
  neighbor, since the driver samples linearly), and swaps the stream — the scene
  graph is static, only the buffer changes.

  Local keyboard is player 1. Debug keys: space pauses/resumes, `.` steps one
  frame while paused, `g` toggles the raw palette-address grayscale view.

  ## Sources
    * Scenic `Assets.Stream` (hand-built `{Bitmap, {w,h,:rgb}, bin}` tuple) and
      `scenic_driver_local` linear sampling — spec §7.
  """
  use Scenic.Scene

  import Scenic.Primitives, only: [rect: 3]
  alias Beamicom.NES.{Output, Palette, Runtime}
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

  @impl true
  def init(scene, params, _opts) do
    scale = Keyword.get(params, :scale, 3)
    {w, h} = {256 * scale, 240 * scale}

    Stream.start_link(nil)
    Stream.put(@stream, {Bitmap, {w, h, :rgb}, :binary.copy(<<0, 0, 0>>, w * h)})
    Output.subscribe()

    graph = Graph.build() |> rect({w, h}, fill: {:stream, @stream})

    scene =
      scene
      |> assign(scale: scale, pressed: MapSet.new(), gray: false, paused: false)
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
  def handle_info({:audio, _samples}, scene), do: {:noreply, scene}

  @impl true
  def handle_input({:key, {key, action, _mods}}, _id, scene) when action in [0, 1] do
    {:noreply, key(key, action == 1, scene)}
  end

  def handle_input(_input, _id, scene) do
    {:noreply, scene}
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

    Runtime.set_buttons(1, MapSet.to_list(pressed))
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
