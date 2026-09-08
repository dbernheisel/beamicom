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

  test "encodes and decodes arbitrary RGB24 dimensions for share images" do
    rgb = :binary.copy(<<1, 2, 3>>, 17 * 9)
    png = PNG.encode_rgb(17, 9, rgb)
    assert {17, 9, ^rgb} = PNG.decode_rgb(png)
  end

  test "round-trips the maximum dimension and rejects dimensions just beyond it" do
    rgb = :binary.copy(<<1, 2, 3>>, 3_072)
    assert {3_072, 1, ^rgb} = 3_072 |> PNG.encode_rgb(1, rgb) |> PNG.decode_rgb()

    too_wide = :binary.copy(<<1, 2, 3>>, 3_073)

    assert_raise ArgumentError, ~r/dimensions exceed limit/, fn ->
      PNG.encode_rgb(3_073, 1, too_wide)
    end
  end

  test "rejects huge IHDR geometry before inflate and bounded IDAT expansion" do
    huge = png([{"IHDR", <<100_000::32, 100_000::32, 8, 2, 0, 0, 0>>}, {"IEND", <<>>}])
    assert_raise ArgumentError, ~r/dimensions exceed limit/, fn -> PNG.decode_rgb(huge) end

    bomb = :zlib.compress(:binary.copy(<<0>>, 1_000_000))
    expanded = png([{"IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>}, {"IDAT", bomb}, {"IEND", <<>>}])
    assert_raise ArgumentError, ~r/expanded PNG image exceeds/, fn -> PNG.decode_rgb(expanded) end
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

  defp png(chunks) do
    signature = <<137, 80, 78, 71, 13, 10, 26, 10>>

    Enum.reduce(chunks, signature, fn {type, data}, image ->
      image <> <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
    end)
  end
end
