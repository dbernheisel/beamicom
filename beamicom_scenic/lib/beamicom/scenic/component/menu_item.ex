defmodule Beamicom.Scenic.Component.MenuItem do
  @moduledoc false

  import Scenic.Primitives, only: [line: 3, rect: 3, text: 3]

  alias Beamicom.Scenic.Theme

  @height 42

  def height, do: @height

  @doc false
  def display_label(item) do
    suffix =
      cond do
        Map.get(item, :toggle, false) -> if(item.checked, do: "  ON", else: "  OFF")
        Map.get(item, :checked, false) -> "  ON"
        true -> ""
      end

    "  " <> item.label <> suffix
  end

  def add_to_graph(graph, :separator, %{width: width, y: y}) do
    line(graph, {{12, y + @height / 2}, {width - 12, y + @height / 2}},
      stroke: {1, {105, 213, 255, 100}}
    )
  end

  def add_to_graph(
        graph,
        item,
        %{width: width, y: y, index: index, id_prefix: id_prefix, selected: selected}
      ) do
    enabled = Map.get(item, :enabled, true)
    selected = selected and enabled

    graph
    |> rect({width - 12, @height - 2},
      id: {id_prefix, index},
      fill: if(selected, do: {105, 213, 255, 75}, else: {5, 10, 32, 15}),
      input: [:cursor_button, :cursor_pos],
      t: {6, y + 1}
    )
    |> text(display_label(item),
      fill: if(enabled, do: Theme.white(), else: Theme.muted()),
      font: :beamicom_ui,
      font_size: 23,
      t: {15, y + 29}
    )
  end
end
