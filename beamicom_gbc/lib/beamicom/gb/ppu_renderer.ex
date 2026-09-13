defmodule Beamicom.GB.PPURenderer do
  @moduledoc """
  Boundary for deferred Game Boy frame composition.

  The live PPU retains LCD timing and VRAM/OAM access rules. A deferred renderer
  receives a frame-start memory snapshot, compact scanline controls, and the
  accepted memory writes tagged with the first line they affect.
  """

  @callback prepare(:dmg | :cgb) :: term()
  @callback render(:dmg | :cgb, map(), term()) :: {binary(), term()}
end
