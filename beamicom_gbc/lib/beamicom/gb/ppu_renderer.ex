defmodule Beamicom.GB.PPURenderer do
  @moduledoc """
  Boundary for deferred Game Boy frame composition.

  The live PPU retains LCD timing and VRAM/OAM access rules. A renderer receives
  144 compact, scanline-timed tile-plane and selected-object rows and performs
  bit-plane expansion, scrolling/window selection, sprite composition,
  priority, and palette work in one frame-sized operation.
  """

  @callback prepare(:dmg | :cgb) :: term()
  @callback render(:dmg | :cgb, [term()], term()) :: {binary(), term()}
end
