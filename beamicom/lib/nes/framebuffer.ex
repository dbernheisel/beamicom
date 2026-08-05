defmodule Beamicom.NES.Framebuffer do
  @moduledoc """
  One rendered PPU frame (spec §6). Pixels are 5-bit palette RAM *addresses*
  (the value before palette lookup), not RGB — sinks resolve colour in two steps
  (palette RAM address → 6-bit master index → RGB) using the 32-byte palette
  snapshot. This keeps palette animation cheap on every output path and lets the
  wire/Scenic/GStreamer sinks share one representation.

  ## Sources
    * NESdev Wiki — PPU palettes / rendering: https://www.nesdev.org/wiki/PPU_palettes
  """

  @enforce_keys [:number, :pixels, :palette]
  defstruct number: 0,
            width: 256,
            height: 240,
            pixels: <<>>,
            palette: <<>>,
            emphasis: {false, false, false},
            grayscale: false,
            region: :ntsc
end
