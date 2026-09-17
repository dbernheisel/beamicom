defmodule Beamicom.SNES.PNG do
  @moduledoc "Dependency-free RGB24 PNG encoding and decoding for SNES frames."

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @max_dimension 3_072
  @max_pixels 9_240_576
  @max_compressed_image_bytes 16 * 1024 * 1024

  alias Beamicom.SNES.BoundedZlib

  @doc "Returns the hard dimension and pixel limits shared by PNG and share-image codecs."
  def limits, do: %{max_dimension: @max_dimension, max_pixels: @max_pixels}

  @doc "Whether dimensions can be safely encoded and decoded by this module."
  def valid_dimensions?(width, height) when is_integer(width) and is_integer(height),
    do:
      width > 0 and height > 0 and width <= @max_dimension and height <= @max_dimension and
        width * height <= @max_pixels

  @spec encode(Beamicom.SNES.PPU.frame()) :: binary()
  def encode(%{width: width, height: height, pixel_format: :rgb24, data: rgb}),
    do: encode_rgb(width, height, rgb)

  @spec encode_rgb(pos_integer(), pos_integer(), binary()) :: binary()
  def encode_rgb(width, height, rgb)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 and
             is_binary(rgb) and byte_size(rgb) == width * height * 3 do
    validate_dimensions!(width, height)
    stride = width * 3
    scanlines = for <<row::binary-size(^stride) <- rgb>>, into: <<>>, do: <<0, row::binary>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    @signature <>
      chunk("IHDR", ihdr) <>
      chunk("IDAT", :zlib.compress(scanlines)) <>
      chunk("IEND", <<>>)
  end

  @doc "Decodes an RGB24 PNG produced by this module."
  def decode_rgb(@signature <> chunks) do
    {width, height, idat, compressed_size} = collect_chunks(chunks, nil, nil, [], 0)
    stride = width * 3
    expected_size = height * (stride + 1)

    if compressed_size > @max_compressed_image_bytes,
      do: raise(ArgumentError, "compressed PNG image exceeds limit")

    raw =
      case BoundedZlib.inflate(:lists.reverse(idat), expected_size) do
        {:ok, inflated} when byte_size(inflated) == expected_size -> inflated
        {:ok, _inflated} -> raise ArgumentError, "invalid PNG image data length"
        {:error, :too_large} -> raise ArgumentError, "expanded PNG image exceeds dimensions"
        {:error, :invalid} -> raise ArgumentError, "invalid PNG image data"
      end

    rgb = for <<0, row::binary-size(^stride) <- raw>>, into: <<>>, do: row
    {width, height, rgb}
  end

  @doc "Returns bytes following the validated PNG IEND chunk."
  def trailing_data(@signature <> chunks), do: find_iend(chunks)
  def trailing_data(_png), do: {:error, :invalid_png}

  defp collect_chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         width,
         height,
         idat,
         compressed_size
       ) do
    unless :erlang.crc32(type <> data) == crc,
      do: raise(ArgumentError, "invalid PNG chunk CRC")

    case type do
      "IHDR" ->
        <<new_width::32, new_height::32, 8, 2, 0, 0, 0>> = data
        validate_dimensions!(new_width, new_height)
        collect_chunks(rest, new_width, new_height, idat, compressed_size)

      "IDAT" ->
        unless is_integer(width) and is_integer(height),
          do: raise(ArgumentError, "PNG IDAT precedes IHDR")

        new_size = compressed_size + length

        if new_size > @max_compressed_image_bytes,
          do: raise(ArgumentError, "compressed PNG image exceeds limit")

        collect_chunks(rest, width, height, [data | idat], new_size)

      "IEND" ->
        unless length == 0 and is_integer(width) and is_integer(height) and idat != [],
          do: raise(ArgumentError, "invalid PNG IEND")

        {width, height, idat, compressed_size}

      _other ->
        collect_chunks(rest, width, height, idat, compressed_size)
    end
  end

  defp collect_chunks(_chunks, _width, _height, _idat, _compressed_size),
    do: raise(ArgumentError, "truncated PNG")

  defp validate_dimensions!(width, height) do
    unless valid_dimensions?(width, height),
      do: raise(ArgumentError, "PNG dimensions exceed limit")
  end

  defp find_iend(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>
       ) do
    if :erlang.crc32(type <> data) != crc do
      {:error, :invalid_png}
    else
      case {type, length} do
        {"IEND", 0} -> {:ok, rest}
        {"IEND", _length} -> {:error, :invalid_png}
        {_type, _length} -> find_iend(rest)
      end
    end
  end

  defp find_iend(_chunks), do: {:error, :invalid_png}

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
end
