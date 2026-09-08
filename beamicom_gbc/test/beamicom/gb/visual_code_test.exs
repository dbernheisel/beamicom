defmodule Beamicom.GB.VisualCodeTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.VisualCode

  @width 160
  @height 144

  test "round-trips its payload and documents centered 4x geometry" do
    payload = :crypto.strong_rand_bytes(12 * 1_024)
    screenshot = patterned_screenshot()
    {width, height, rgb} = VisualCode.encode(payload, screenshot)

    assert {:ok, ^payload} = VisualCode.decode(rgb, width, height)
    assert {:ok, {left, top, 640, 576}} = VisualCode.screenshot_rect(width, height)
    assert left == top
    assert width == 640 + 2 * left
    assert height == 576 + 2 * top
    assert rem(left, 2) == 0
  end

  test "centers and nearest-neighbor replicates every native pixel 4x" do
    screenshot = patterned_screenshot()
    {width, height, rgb} = VisualCode.encode(<<1, 2, 3>>, screenshot)
    {:ok, {left, top, 640, 576}} = VisualCode.screenshot_rect(width, height)

    for {native_x, native_y} <- [{0, 0}, {1, 0}, {79, 71}, {159, 143}],
        dy <- 0..3,
        dx <- 0..3 do
      expected = binary_part(screenshot, (native_y * @width + native_x) * 3, 3)
      x = left + native_x * 4 + dx
      y = top + native_y * 4 + dy
      assert binary_part(rgb, (y * width + x) * 3, 3) == expected
    end
  end

  test "rejects corrupted border data and foreign geometry" do
    {width, height, rgb} = VisualCode.encode("state", patterned_screenshot())
    offset = (width + 1) * 3
    <<head::binary-size(^offset), byte, rest::binary>> = rgb
    corrupt = <<head::binary, 255 - byte, rest::binary>>

    assert {:error, :undecodable} = VisualCode.decode(corrupt, width, height)
    assert {:error, :bad_geometry} = VisualCode.decode(<<0, 0, 0>>, 1, 1)
  end

  test "maximum capacity is derived from the shared PNG bounds and the next byte is rejected before rendering" do
    maximum = VisualCode.max_payload_bytes()
    screenshot = :binary.copy(<<0, 64, 192>>, @width * @height)

    # At 608 border cells the image is exactly on the shared pixel limit.
    # One more cell exceeds both the dimension and pixel bounds. The capacity
    # removes the 13-byte visual-code header from the border's bit budget.
    assert Beamicom.GB.PNG.limits() == %{max_dimension: 3_072, max_pixels: 9_240_576}
    assert Beamicom.GB.PNG.valid_dimensions?(3_072, 3_008)
    refute Beamicom.GB.PNG.valid_dimensions?(3_076, 3_012)
    assert maximum == div(1_536 * 1_504 - 320 * 288, 8) - 13
    assert maximum == 277_235

    assert_raise ArgumentError, ~r/exceeds safe geometry capacity/, fn ->
      VisualCode.encode(:binary.copy(<<0xA5>>, maximum + 1), screenshot)
    end
  end

  defp patterned_screenshot do
    for y <- 0..(@height - 1), x <- 0..(@width - 1), into: <<>> do
      <<rem(x * 3 + y, 256), rem(x + y * 5, 256), rem(x * 7 + y * 11, 256)>>
    end
  end
end
