defmodule Beamicom.NES.Palette do
  @moduledoc """
  The 64-entry 2C02 master palette and the palette-address → RGB resolution
  (spec §6). A framebuffer pixel is a 5-bit palette RAM address; resolving it is
  two steps: address → 6-bit master index (via the frame's 32-byte palette
  snapshot, AND $30 when grayscale) → RGB from the master table.

  ponytail: color-emphasis (spec §6) is not yet applied — add the eight
  precomputed table variants when a consumer needs emphasis. The master table is
  a common 2C02 approximation; spec §13 leaves the exact palette swappable.

  ## Sources
    * NESdev Wiki — PPU palettes: https://www.nesdev.org/wiki/PPU_palettes
  """

  import Bitwise

  # 64 RGB triples (2C02, FCEUX-style approximation).
  @master {
    {84, 84, 84},
    {0, 30, 116},
    {8, 16, 144},
    {48, 0, 136},
    {68, 0, 100},
    {92, 0, 48},
    {84, 4, 0},
    {60, 24, 0},
    {32, 42, 0},
    {8, 58, 0},
    {0, 64, 0},
    {0, 60, 0},
    {0, 50, 60},
    {0, 0, 0},
    {0, 0, 0},
    {0, 0, 0},
    {152, 150, 152},
    {8, 76, 196},
    {48, 50, 236},
    {92, 30, 228},
    {136, 20, 176},
    {160, 20, 100},
    {152, 34, 32},
    {120, 60, 0},
    {84, 90, 0},
    {40, 114, 0},
    {8, 124, 0},
    {0, 118, 40},
    {0, 102, 120},
    {0, 0, 0},
    {0, 0, 0},
    {0, 0, 0},
    {236, 238, 236},
    {76, 154, 236},
    {120, 124, 236},
    {176, 98, 236},
    {228, 84, 236},
    {236, 88, 180},
    {236, 106, 100},
    {212, 136, 32},
    {160, 170, 0},
    {116, 196, 0},
    {76, 208, 32},
    {56, 204, 108},
    {56, 180, 204},
    {60, 60, 60},
    {0, 0, 0},
    {0, 0, 0},
    {236, 238, 236},
    {168, 204, 236},
    {188, 188, 236},
    {212, 178, 236},
    {236, 174, 236},
    {236, 174, 212},
    {236, 180, 176},
    {228, 196, 144},
    {204, 210, 120},
    {180, 222, 120},
    {168, 226, 144},
    {152, 226, 180},
    {160, 214, 228},
    {160, 162, 160},
    {0, 0, 0},
    {0, 0, 0}
  }

  @doc "RGB tuple for a 6-bit master palette index (0-63)."
  def rgb(index), do: elem(@master, index &&& 0x3F)

  @doc "Resolve a %Framebuffer{} to a width*height*3 RGB binary."
  def to_rgb(%Beamicom.NES.Framebuffer{pixels: pixels, palette: palette, grayscale: gray}) do
    mask = if gray, do: 0x30, else: 0x3F

    for <<addr <- pixels>>, into: <<>> do
      {r, g, b} = rgb(:binary.at(palette, addr) &&& mask)
      <<r, g, b>>
    end
  end

  @doc """
  Debug view (spec §7): resolve a frame to a native width*height*3 RGB binary
  where each pixel is the raw 5-bit palette-RAM *address* as grayscale, showing
  PPU output before any palette mapping.
  """
  def to_addr_gray(%Beamicom.NES.Framebuffer{pixels: pixels}) do
    for <<addr <- pixels>>, into: <<>> do
      g = addr <<< 3
      <<g, g, g>>
    end
  end
end
