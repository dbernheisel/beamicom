defmodule Beamicom.Scenic.Component.StatusBar do
  @moduledoc "Bottom status strip shared by idle and active shell modes."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [rect: 3, text: 3]

  alias Beamicom.Scenic.Theme
  alias Scenic.Graph

  @height 48

  @impl Scenic.Component
  def validate(%{size: {width, height}} = data)
      when is_number(width) and width > 0 and is_number(height) and height > 0,
      do: {:ok, data}

  def validate(data),
    do: {:error, "expected status data with a positive :size, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds(%{size: {width, _height}}, _styles), do: {0, 0, width, @height}

  @impl Scenic.Scene
  def init(scene, data, _opts) do
    {width, _height} = data.size
    graph = build_graph(width, data)
    {:ok, push_graph(scene, graph)}
  end

  def height, do: @height

  defp build_graph(width, data) do
    fps = Map.get(data, :fps)
    rom = Map.get(data, :rom)
    controller = Map.get(data, :controller, "pad 1: --")
    message = Map.get(data, :message)

    Graph.build()
    |> rect({width, @height}, fill: {7, 28, 72, 235}, stroke: {2, Theme.cyan()})
    |> text(if(fps, do: "FPS #{format_fps(fps)}", else: "FPS --"),
      fill: Theme.white(),
      font: :beamicom_ui,
      font_size: 18,
      t: {18, 31}
    )
    |> text(if(rom, do: "ROM: #{rom}", else: "ROM: none"),
      fill: Theme.muted(),
      font: :beamicom_ui,
      font_size: 18,
      t: {width * 0.27, 31}
    )
    |> text(message || controller,
      fill: if(message, do: Theme.white(), else: Theme.cyan()),
      font: :beamicom_ui,
      font_size: 18,
      text_align: :right,
      t: {width - 18, 31}
    )
  end

  defp format_fps(fps) when is_integer(fps), do: "#{fps}.0"
  defp format_fps(fps) when is_float(fps), do: :erlang.float_to_binary(fps, decimals: 1)
end
