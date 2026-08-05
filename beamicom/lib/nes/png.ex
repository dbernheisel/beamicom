defmodule Beamicom.NES.PNG do
  @moduledoc """
  Minimal truecolor PNG encoder/decoder (no external deps — uses built-in `:zlib`).

  ## Sources
    * PNG spec (RFC 2083): IHDR/IDAT/IEND chunks, filter-0 scanlines, zlib IDAT.
  """

  # ponytail: decode handles only our own output subset: 8-bit truecolor, filter-0,
  # no interlace. Not a general PNG reader.
  @trailer_magic "BMIC\x00SAVE"

  @doc "Encode a width*height*3 RGB binary as a PNG binary."
  def encode(width, height, rgb) do
    stride = width * 3
    raw = for <<row::binary-size(^stride) <- rgb>>, into: <<>>, do: <<0, row::binary>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")
  end

  @doc "Decode a PNG binary produced by encode/3. Returns {width, height, rgb}."
  def decode(png_binary) do
    <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = png_binary
    {width, height, idat} = collect_chunks(rest, nil, nil, <<>>)
    raw = :zlib.uncompress(idat)
    stride = width * 3
    rgb = for <<_filter::8, row::binary-size(^stride) <- raw>>, into: <<>>, do: row
    {width, height, rgb}
  end

  @doc "Append a raw blob after the PNG IEND chunk (survives byte-exact file transfer)."
  def put_trailer(png_binary, blob),
    do: png_binary <> @trailer_magic <> <<byte_size(blob)::32>> <> blob

  @doc "Extract the blob appended by put_trailer/2. Returns {:ok, blob} or :none."
  def get_trailer(png_binary) do
    case :binary.match(png_binary, @trailer_magic) do
      :nomatch ->
        :none

      {pos, _} ->
        magic_len = byte_size(@trailer_magic)

        <<_::binary-size(^pos), _::binary-size(^magic_len), len::32, blob::binary-size(len),
          _::binary>> = png_binary

        {:ok, blob}
    end
  end

  defp collect_chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         w,
         h,
         idat
       ) do
    case type do
      "IHDR" ->
        <<nw::32, nh::32, _::binary>> = data
        collect_chunks(rest, nw, nh, idat)

      "IDAT" ->
        collect_chunks(rest, w, h, idat <> data)

      "IEND" ->
        {w, h, idat}

      _ ->
        collect_chunks(rest, w, h, idat)
    end
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
end
