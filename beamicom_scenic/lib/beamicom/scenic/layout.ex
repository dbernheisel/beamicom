defmodule Beamicom.Scenic.Layout do
  @moduledoc false

  @type placement :: %{
          position: {number(), number()},
          output_size: {pos_integer(), pos_integer()},
          scale: number(),
          integer_scale: pos_integer() | nil
        }

  @spec fit(
          {pos_integer(), pos_integer()},
          {pos_integer(), pos_integer()},
          {number(), number()},
          {number(), number()},
          boolean()
        ) :: placement()
  def fit(base_size, source_size, origin, available_size, integer?)

  def fit({base_width, base_height}, _source_size, {left, top}, {max_width, max_height}, true) do
    stage = max(1, floor(min(max_width / base_width, max_height / base_height)))
    output_width = base_width * stage
    output_height = base_height * stage

    %{
      position: {
        round(left) + div(round(max_width) - output_width, 2),
        round(top) + div(round(max_height) - output_height, 2)
      },
      output_size: {output_width, output_height},
      scale: 1.0,
      integer_scale: stage
    }
  end

  def fit(_base_size, {source_width, source_height}, {left, top}, {max_width, max_height}, false) do
    scale = min(max_width / source_width, max_height / source_height)
    surface_width = source_width * scale
    surface_height = source_height * scale

    %{
      position: {
        left + (max_width - surface_width) / 2,
        top + (max_height - surface_height) / 2
      },
      output_size: {source_width, source_height},
      scale: scale,
      integer_scale: nil
    }
  end
end
