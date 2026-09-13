defmodule Beamicom.GB.PPURenderer do
  @moduledoc """
  Boundary for deferred Game Boy frame composition.

  The live PPU retains LCD timing, VRAM/OAM access rules, tile addressing,
  window state, and sprite selection. A renderer receives the 144 captured
  scanlines and performs the regular pixel-priority and palette work in one
  frame-sized operation.
  """

  @callback prepare(:dmg | :cgb) :: term()
  @callback render(:dmg | :cgb, [term()], term()) :: {binary(), term()}
end
