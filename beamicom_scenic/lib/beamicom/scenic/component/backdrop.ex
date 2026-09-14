defmodule Beamicom.Scenic.Component.Backdrop do
  @moduledoc "Static backdrop, perspective guides, scanlines, and border."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [line: 3, rect: 3]

  alias Beamicom.Scenic.Theme
  alias Scenic.Graph

  @inset 22
  @horizon_ratio 0.59

  @impl Scenic.Component
  def validate({width, height} = size)
      when is_number(width) and width > 0 and is_number(height) and height > 0,
      do: {:ok, size}

  def validate(data), do: {:error, "expected a positive {width, height}, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds({width, height}, _styles), do: {0, 0, width, height}

  @impl Scenic.Scene
  def init(scene, {width, height}, _opts) do
    horizon = horizon(height)
    bottom = height - @inset
    vanishing_x = width / 2

    graph =
      Graph.build()
      |> rect({width, height}, fill: Theme.navy())
      |> line({{@inset, horizon}, {width - @inset, horizon}}, stroke: {2, Theme.blue()})
      |> add_perspective_lines(width, horizon, bottom, vanishing_x)
      |> add_scanlines(width, height)
      |> rect({width - @inset * 2, height - @inset * 2},
        t: {@inset, @inset},
        stroke: {2, {105, 213, 255, 110}}
      )

    {:ok, push_graph(scene, graph)}
  end

  defp add_perspective_lines(graph, width, horizon, bottom, vanishing_x) do
    Enum.reduce(0..12, graph, fn index, graph ->
      bottom_x = @inset + (width - @inset * 2) * index / 12

      line(graph, {{vanishing_x, horizon}, {bottom_x, bottom}}, stroke: {1, {24, 94, 202, 190}})
    end)
  end

  @doc false
  def horizon(height), do: @inset + (height - @inset * 2) * @horizon_ratio

  defp add_scanlines(graph, width, height) do
    Enum.reduce(0..div(round(height), 4), graph, fn index, graph ->
      rect(graph, {width, 1}, fill: {0, 0, 0, 34}, t: {0, index * 4})
    end)
  end
end
