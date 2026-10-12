defmodule Beamicom.Scenic.Text do
  @moduledoc "Text measurement and fitting for the Scenic shell."

  alias Scenic.Assets.Static

  @font :beamicom_ui
  @ellipsis "…"

  def width(text, font_size) when is_binary(text) and is_number(font_size) do
    case Static.meta(@font) do
      {:ok, {Static.Font, metrics}} -> FontMetrics.width(text, font_size, metrics)
      _error -> String.length(text) * font_size
    end
  end

  def fit(text, maximum_width, font_size)
      when is_binary(text) and is_number(maximum_width) and is_number(font_size) do
    cond do
      maximum_width <= 0 -> ""
      width(text, font_size) <= maximum_width -> text
      width(@ellipsis, font_size) > maximum_width -> ""
      true -> fit_with_ellipsis(text, maximum_width, font_size)
    end
  end

  defp fit_with_ellipsis(text, maximum_width, font_size) do
    graphemes = String.graphemes(text)
    prefix_length = longest_prefix(graphemes, maximum_width, font_size, 0, length(graphemes))
    graphemes |> Enum.take(prefix_length) |> Enum.join() |> Kernel.<>(@ellipsis)
  end

  defp longest_prefix(_graphemes, _maximum_width, _font_size, low, high) when low >= high,
    do: low

  defp longest_prefix(graphemes, maximum_width, font_size, low, high) do
    middle = div(low + high + 1, 2)
    candidate = graphemes |> Enum.take(middle) |> Enum.join() |> Kernel.<>(@ellipsis)

    if width(candidate, font_size) <= maximum_width do
      longest_prefix(graphemes, maximum_width, font_size, middle, high)
    else
      longest_prefix(graphemes, maximum_width, font_size, low, middle - 1)
    end
  end
end
