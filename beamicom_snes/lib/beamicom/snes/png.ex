defmodule Beamicom.SNES.PNG do
  @moduledoc "Dependency-free RGB24 PNG encoding for native SNES frames."

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @spec encode(Beamicom.SNES.PPU.frame()) :: binary()
  def encode(%{width: width, height: height, pixel_format: :rgb24, data: rgb}),
    do: encode_rgb(width, height, rgb)

  @spec encode_rgb(pos_integer(), pos_integer(), binary()) :: binary()
  def encode_rgb(width, height, rgb)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 and
             is_binary(rgb) and byte_size(rgb) == width * height * 3 do
    stride = width * 3
    scanlines = for <<row::binary-size(^stride) <- rgb>>, into: <<>>, do: <<0, row::binary>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    @signature <>
      chunk("IHDR", ihdr) <>
      chunk("IDAT", :zlib.compress(scanlines)) <>
      chunk("IEND", <<>>)
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
end
