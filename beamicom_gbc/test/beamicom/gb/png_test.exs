defmodule Beamicom.GB.PNGTest do
  use ExUnit.Case, async: true

  alias Beamicom.GB.PNG

  test "encodes native shade indices as a valid truecolor PNG" do
    row = for x <- 0..159, into: <<>>, do: <<rem(div(x, 40), 4)>>
    frame = :binary.copy(row, 144)
    png = PNG.encode(frame, palette: :grayscale)

    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert {160, 144, rgb} = PNG.decode(png)
    assert byte_size(rgb) == 160 * 144 * 3

    assert binary_part(rgb, 0, 12) == :binary.copy(<<0xFF, 0xFF, 0xFF>>, 4)
    assert binary_part(rgb, 40 * 3, 3) == <<0xAA, 0xAA, 0xAA>>
    assert binary_part(rgb, 80 * 3, 3) == <<0x55, 0x55, 0x55>>
    assert binary_part(rgb, 120 * 3, 3) == <<0, 0, 0>>
  end

  test "palette selection changes RGB output without changing shade indices" do
    frame = :binary.copy(<<0, 1, 2, 3>>, div(160 * 144, 4))

    refute PNG.encode(frame, palette: :grayscale) == PNG.encode(frame, palette: :dmg_green)
    refute PNG.to_rgb(frame, :grayscale) == PNG.to_rgb(frame, :dmg_green)
  end

  test "encodes native CGB RGB24 without palette remapping" do
    pixel = <<0x12, 0xA4, 0xFE>>
    frame = :binary.copy(pixel, 160 * 144)
    png = PNG.encode(frame, pixel_format: :rgb24, palette: :grayscale)

    assert {160, 144, ^frame} = PNG.decode(png)
    assert PNG.to_rgb(frame, :rgb24, :dmg_green) == frame
  end

  test "rejects malformed native frames and unsupported palettes" do
    assert_raise ArgumentError, ~r/expected 23040/, fn -> PNG.encode(<<0>>) end

    assert_raise ArgumentError, ~r/invalid DMG shade/, fn ->
      PNG.encode(:binary.copy(<<4>>, 160 * 144))
    end

    assert_raise ArgumentError, ~r/unsupported DMG palette/, fn ->
      PNG.encode(:binary.copy(<<0>>, 160 * 144), palette: :amber)
    end

    assert_raise ArgumentError, ~r/expected 69120 RGB24/, fn ->
      PNG.encode(<<0>>, pixel_format: :rgb24)
    end
  end
end
