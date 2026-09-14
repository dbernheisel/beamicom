defmodule Beamicom.Scenic.Component.MenuItem do
  @moduledoc false

  import Scenic.Primitives, only: [circle: 3, line: 3, rect: 3, text: 3]

  alias Beamicom.Scenic.Theme

  @height 42
  @font_size 23
  @slider_gap 30
  @slider_end_padding 28

  def height, do: @height

  @doc false
  def display_label(item) do
    suffix =
      cond do
        slider?(item) -> "  #{item.slider.value} pct"
        Map.get(item, :toggle, false) -> if(item.checked, do: "  ON", else: "  OFF")
        Map.get(item, :checked, false) -> "  ON"
        true -> ""
      end

    "  " <> item.label <> suffix
  end

  @doc false
  def slider?(%{slider: %{min: min, max: max, value: value}})
      when is_integer(min) and is_integer(max) and is_integer(value),
      do: true

  def slider?(_item), do: false

  @doc false
  def slider_value(%{slider: slider} = item, width, x) do
    {track_start, track_end} = slider_track(item, width)
    x = x |> max(track_start) |> min(track_end)
    percent = (x - track_start) / (track_end - track_start)
    raw_value = slider.min + round((slider.max - slider.min) * percent)
    stepped_value = slider.min + round((raw_value - slider.min) / slider.step) * slider.step
    stepped_value |> max(slider.min) |> min(slider.max)
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

    graph =
      rect(graph, {width - 12, @height - 2},
        id: {id_prefix, index},
        fill: if(selected, do: {105, 213, 255, 75}, else: {5, 10, 32, 15}),
        input: [:cursor_button, :cursor_pos],
        t: {6, y + 1}
      )

    graph =
      text(graph, display_label(item),
        fill: if(enabled, do: Theme.white(), else: Theme.muted()),
        font: :beamicom_ui,
        font_size: @font_size,
        t: {15, y + 29}
      )

    if slider?(item), do: add_slider(graph, item, width, y, enabled), else: graph
  end

  defp add_slider(graph, item, width, y, enabled) do
    {track_start, track_end} = slider_track(item, width)
    slider = item.slider
    percent = (slider.value - slider.min) / (slider.max - slider.min)
    thumb_x = track_start + (track_end - track_start) * percent
    color = if enabled, do: Theme.cyan(), else: Theme.muted()

    graph
    |> line({{track_start, y + @height / 2}, {track_end, y + @height / 2}},
      stroke: {4, color}
    )
    |> circle(7, fill: color, t: {thumb_x, y + @height / 2})
  end

  defp slider_track(item, width) do
    label_end = 15 + text_width(display_label(item))
    {label_end + @slider_gap, width - @slider_end_padding}
  end

  defp text_width(text) do
    case Scenic.Assets.Static.meta(:beamicom_ui) do
      {:ok, {Scenic.Assets.Static.Font, metrics}} -> FontMetrics.width(text, @font_size, metrics)
      _error -> String.length(text) * @font_size
    end
  end
end
