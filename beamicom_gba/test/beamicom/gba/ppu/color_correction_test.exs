defmodule Beamicom.GBA.PPU.ColorCorrectionTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.PPU.ColorCorrection

  test "applies the configured VBA LCD transform to BGR555 colors" do
    assert ColorCorrection.rgb24(0x0000) == <<0, 0, 0>>
    assert ColorCorrection.rgb24(0x001F) == <<221, 24, 26>>
    assert ColorCorrection.rgb24(0x03E0) == <<85, 223, 72>>
    assert ColorCorrection.rgb24(0x7C00) == <<0, 103, 230>>
    assert ColorCorrection.rgb24(0x7FFF) == <<255, 255, 255>>
  end

  test "ignores the unused high BGR555 bit" do
    assert ColorCorrection.rgb24(0x801F) == ColorCorrection.rgb24(0x001F)
  end
end
