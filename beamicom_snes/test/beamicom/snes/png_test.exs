defmodule Beamicom.SNES.PNGTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.PNG

  test "encodes an RGB24 frame with valid PNG framing" do
    rgb = <<255, 0, 0, 0, 255, 0>>
    png = PNG.encode_rgb(2, 1, rgb)
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert :binary.match(png, "IHDR") != :nomatch
    assert :binary.match(png, "IDAT") != :nomatch
    assert :binary.match(png, "IEND") != :nomatch
    assert PNG.decode_rgb(png) == {2, 1, rgb}
    assert PNG.trailing_data(png <> "trailer") == {:ok, "trailer"}
  end

  test "rejects corrupt and oversized PNG input" do
    png = PNG.encode_rgb(1, 1, <<0, 0, 0>>)
    <<head::binary-size(20), byte, rest::binary>> = png

    assert_raise ArgumentError, fn -> PNG.decode_rgb(<<head::binary, byte + 1, rest::binary>>) end

    assert_raise ArgumentError, fn ->
      PNG.encode_rgb(3_073, 1, :binary.copy(<<0, 0, 0>>, 3_073))
    end
  end
end
