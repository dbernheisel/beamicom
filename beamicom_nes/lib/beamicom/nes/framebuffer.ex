defmodule Beamicom.NES.Framebuffer do
  @moduledoc """
  One rendered PPU frame (spec §6). Pixels are 5-bit palette RAM *addresses*
  (the value before palette lookup), not RGB — sinks resolve colour in two steps
  (palette RAM address → 6-bit master index → RGB) using the 32-byte palette
  snapshot. A renderer may also attach the resolved RGB binary so every output
  sink can reuse one palette expansion.

  ## Sources
    * NESdev Wiki — PPU palettes / rendering: https://www.nesdev.org/wiki/PPU_palettes
  """

  @enforce_keys [:number, :pixels, :palette]
  defstruct number: 0,
            width: 256,
            height: 240,
            pixels: <<>>,
            palette: <<>>,
            rgb: nil,
            # Optional frame-wide renderer invocation resolved by NES.System so
            # video and audio EXLA programs can run concurrently.
            render: nil,
            # Presentation-only horizontal overscan mask. The PPU still renders
            # all 256 pixels; RGB consumers replace this many pixels at both
            # edges with black.
            edge_mask: 0,
            emphasis: {false, false, false},
            grayscale: false,
            region: :ntsc
end
