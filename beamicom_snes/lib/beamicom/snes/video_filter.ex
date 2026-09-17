defmodule Beamicom.SNES.VideoFilter do
  @moduledoc "Presentation-filter contract used by the SNES PPU."

  @callback prepare(keyword()) :: term()
  @callback filter(binary(), non_neg_integer(), term()) :: binary()
  @callback output_width() :: pos_integer()
  @callback pixel_scale() :: {pos_integer(), pos_integer()}
end
