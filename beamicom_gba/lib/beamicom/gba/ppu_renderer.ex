defmodule Beamicom.GBA.PPURenderer do
  @moduledoc """
  Boundary for deterministic Game Boy Advance frame composition.

  The scalar machine owns PPU timing and display memory. Renderers receive a
  packed snapshot only after timing has established a frame boundary.
  """

  @callback render_mode0(binary(), binary(), binary(), map()) :: binary()
  @callback render_mode1(binary(), binary(), binary(), map()) :: binary()
  @callback render_mode3(binary(), binary(), binary(), map()) :: binary()
end
