defmodule Beamicom.Scenic.Component.PopupMenu do
  @moduledoc false

  import Scenic.Primitives, only: [rect: 3]

  alias Beamicom.Scenic.Component.MenuItem
  alias Beamicom.Scenic.Theme

  @minimum_width 286
  @maximum_width 760
  @font_size 23
  @horizontal_padding 38

  def width(items) do
    label_width =
      items
      |> Enum.reject(&(&1 == :separator))
      |> Enum.map(&text_width(MenuItem.display_label(&1)))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(@horizontal_padding)
      |> ceil()

    label_width |> max(@minimum_width) |> min(@maximum_width)
  end

  defp text_width(text) do
    case Scenic.Assets.Static.meta(:beamicom_ui) do
      {:ok, {Scenic.Assets.Static.Font, metrics}} -> FontMetrics.width(text, @font_size, metrics)
      _error -> String.length(text) * @font_size
    end
  end

  def add_to_graph(graph, items, selected_item, id_prefix \\ :menu_item) do
    width = width(items)
    height = length(items) * MenuItem.height() + 12

    graph =
      rect(graph, {width, height},
        fill: {7, 28, 72, 244},
        stroke: {2, Theme.cyan()},
        input: [:cursor_button, :cursor_pos]
      )

    items
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {item, index}, graph ->
      MenuItem.add_to_graph(graph, item, %{
        width: width,
        y: 6 + index * MenuItem.height(),
        index: index,
        id_prefix: id_prefix,
        selected: index == selected_item
      })
    end)
  end
end
