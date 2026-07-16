defmodule Beamicom.NES.PNGTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.PNG

  test "encode/decode round-trips a 4×3 RGB image" do
    w = 4
    h = 3
    rgb = :crypto.strong_rand_bytes(w * h * 3)
    {dw, dh, drgb} = PNG.decode(PNG.encode(w, h, rgb))
    assert dw == w
    assert dh == h
    assert drgb == rgb
  end

  test "decode ignores unknown chunks" do
    w = 2
    h = 2
    rgb = <<255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0>>
    png = PNG.encode(w, h, rgb)
    # inject a fake tEXt chunk after IHDR
    sig = <<137, 80, 78, 71, 13, 10, 26, 10>>
    <<^sig::binary-size(8), rest::binary>> = png
    fake = <<0, 0, 0, 5>> <> "tEXt" <> "hello" <> <<:erlang.crc32("tEXt" <> "hello")::32>>
    with_chunk = sig <> fake <> rest
    assert {^w, ^h, ^rgb} = PNG.decode(with_chunk)
  end

  test "put_trailer/get_trailer round-trips" do
    png = PNG.encode(2, 2, <<0::96>>)
    blob = <<"save state data">>
    assert {:ok, ^blob} = png |> PNG.put_trailer(blob) |> PNG.get_trailer()
  end

  test "get_trailer returns :none when absent" do
    png = PNG.encode(2, 2, <<0::96>>)
    assert :none = PNG.get_trailer(png)
  end

  test "get_trailer survives extra bytes after IEND (no trailer magic)" do
    png = PNG.encode(2, 2, <<0::96>>)
    assert :none = PNG.get_trailer(png <> <<"random garbage">>)
  end
end
