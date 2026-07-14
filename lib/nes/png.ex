defmodule Beamicom.NES.PNG do
  @moduledoc """
  Minimal truecolor PNG encoder (no external deps — uses built-in `:zlib`).
  Enough to save a framebuffer as a viewable screenshot.

  ## Sources
    * PNG spec (RFC 2083): IHDR/IDAT/IEND chunks, filter-0 scanlines, zlib IDAT.
  """

  @doc "Encode a width*height*3 RGB binary as a PNG binary."
  def encode(width, height, rgb) do
    stride = width * 3
    raw = for <<row::binary-size(^stride) <- rgb>>, into: <<>>, do: <<0, row::binary>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
end
