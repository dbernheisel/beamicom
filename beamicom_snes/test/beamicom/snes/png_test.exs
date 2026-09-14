defmodule Beamicom.SNES.PNGTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.PNG

  test "encodes an RGB24 frame with valid PNG framing" do
    png = PNG.encode_rgb(2, 1, <<255, 0, 0, 0, 255, 0>>)
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert :binary.match(png, "IHDR") != :nomatch
    assert :binary.match(png, "IDAT") != :nomatch
    assert :binary.match(png, "IEND") != :nomatch
  end
end
