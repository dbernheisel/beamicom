defmodule Beamicom.SNES.VisualCodeTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.VisualCode

  @width 256
  @height 224

  test "round-trips a payload around a centered four-times screenshot" do
    payload = :crypto.strong_rand_bytes(4 * 1_024)
    screenshot = patterned_screenshot()
    {width, height, rgb} = VisualCode.encode(payload, screenshot)

    assert {:ok, ^payload} = VisualCode.decode(rgb, width, height)
    assert :snes = VisualCode.classify(rgb, width, height)
    assert {:ok, {left, top, 1024, 896}} = VisualCode.screenshot_rect(width, height)
    assert left == top
    assert width == 1024 + 2 * left
    assert height == 896 + 2 * top
  end

  test "rejects a corrupted border and foreign geometry" do
    {width, height, rgb} = VisualCode.encode("state", patterned_screenshot())
    offset = (width + 1) * 3
    <<head::binary-size(^offset), byte, rest::binary>> = rgb
    corrupt = <<head::binary, 255 - byte, rest::binary>>

    assert {:error, :undecodable} = VisualCode.decode(corrupt, width, height)
    assert {:error, :bad_geometry} = VisualCode.decode(<<0, 0, 0>>, 1, 1)
  end

  defp patterned_screenshot do
    for y <- 0..(@height - 1), x <- 0..(@width - 1), into: <<>> do
      <<rem(x * 3 + y, 256), rem(x + y * 5, 256), rem(x * 7 + y * 11, 256)>>
    end
  end
end
