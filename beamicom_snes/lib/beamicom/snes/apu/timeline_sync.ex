defmodule Beamicom.SNES.APU.TimelineSync do
  @moduledoc false

  @enforce_keys [:preview_clock, :end_clock, :renderer]
  defstruct [:preview_clock, :end_clock, :renderer, boundary: nil, dependencies: nil, pcm: []]
end
