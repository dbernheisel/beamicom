defmodule Beamicom.Scenic.Component.MenuItem do
  @moduledoc false

  import Scenic.Primitives, only: [circle: 3, line: 3, rect: 3, text: 3]

  alias Beamicom.Scenic.{Text, Theme}

  @height 42
  @font_size 23
  @slider_gap 30
  @slider_end_padding 28
  @slider_minimum_width 140

  def height, do: @height

  @doc false
  def display_label(item) do
    suffix =
      cond do
        slider?(item) -> "  #{item.slider.value}"
        Map.get(item, :toggle, false) -> if(item.checked, do: "  ON", else: "  OFF")
        Map.get(item, :checked, false) -> "  ON"
        true -> ""
      end

    "  " <> item.label <> suffix
  end

  @doc false
  def layout_label(%{slider: slider} = item),
    do: item |> put_in([:slider, :value], slider.max) |> display_label()

  def layout_label(item), do: display_label(item)

  @doc false
  def fitted_label(item, width) do
    maximum_width =
      if slider?(item),
        do: slider_label_width(width),
        else: max(width - 30, 0)

    Text.fit(display_label(item), maximum_width, @font_size)
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
      text(graph, fitted_label(item, width),
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
    label = Text.fit(layout_label(item), slider_label_width(width), @font_size)
    label_end = 15 + text_width(label)
    {label_end + @slider_gap, width - @slider_end_padding}
  end

  defp slider_label_width(width),
    do: max(width - 15 - @slider_gap - @slider_end_padding - @slider_minimum_width, 0)

  defp text_width(text), do: Text.width(text, @font_size)
end
