defmodule Beamicom.Scenic.Component.Backdrop do
  @moduledoc "Static backdrop, perspective guides, scanlines, and border."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [line: 3, rect: 3]

  alias Beamicom.Scenic.Theme
  alias Scenic.Graph

  @impl Scenic.Component
  def validate({width, height} = size)
      when is_number(width) and width > 0 and is_number(height) and height > 0,
      do: {:ok, size}

  def validate(data), do: {:error, "expected a positive {width, height}, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds({width, height}, _styles), do: {0, 0, width, height}

  @impl Scenic.Scene
  def init(scene, {width, height}, _opts) do
    horizon = height * 0.59
    bottom = height - 22
    vanishing_x = width / 2

    graph =
      Graph.build()
      |> rect({width, height}, fill: Theme.navy())
      |> line({{22, horizon}, {width - 22, horizon}}, stroke: {2, Theme.blue()})
      |> add_perspective_lines(width, horizon, bottom, vanishing_x)
      |> add_scanlines(width, height)
      |> rect({width - 44, height - 44},
        t: {22, 22},
        stroke: {2, {105, 213, 255, 110}}
      )

    {:ok, push_graph(scene, graph)}
  end

  defp add_perspective_lines(graph, width, horizon, bottom, vanishing_x) do
    Enum.reduce(0..12, graph, fn index, graph ->
      bottom_x = 22 + (width - 44) * index / 12

      line(graph, {{vanishing_x, horizon}, {bottom_x, bottom}}, stroke: {1, {24, 94, 202, 190}})
    end)
  end

  defp add_scanlines(graph, width, height) do
    Enum.reduce(0..div(round(height), 4), graph, fn index, graph ->
      rect(graph, {width, 1}, fill: {0, 0, 0, 34}, t: {0, index * 4})
    end)
  end
end
