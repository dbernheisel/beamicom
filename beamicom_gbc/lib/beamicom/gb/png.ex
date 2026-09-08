defmodule Beamicom.GB.PNG do
  @moduledoc """
  Dependency-free PNG encoding for native 160×144 DMG and CGB frames.

  DMG input contains one shade index per pixel; CGB input is already RGB24.
  The encoder emits non-interlaced, 8-bit truecolor PNG data with filter-zero
  scanlines and uses the OTP-provided `:zlib` module.
  """

  @width 160
  @height 144
  @frame_bytes @width * @height
  @rgb_frame_bytes @frame_bytes * 3
  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @max_dimension 3_072
  @max_pixels 9_240_576
  @max_compressed_image_bytes 16 * 1024 * 1024

  alias Beamicom.GB.BoundedZlib

  @doc "Returns the hard dimension and pixel limits shared by PNG and share-image codecs."
  @spec limits() :: %{max_dimension: pos_integer(), max_pixels: pos_integer()}
  def limits, do: %{max_dimension: @max_dimension, max_pixels: @max_pixels}

  @doc "Whether dimensions can be safely encoded and decoded by this module."
  @spec valid_dimensions?(integer(), integer()) :: boolean()
  def valid_dimensions?(width, height) when is_integer(width) and is_integer(height),
    do:
      width > 0 and height > 0 and width <= @max_dimension and height <= @max_dimension and
        width * height <= @max_pixels

  @palettes %{
    grayscale: {
      <<0xFF, 0xFF, 0xFF>>,
      <<0xAA, 0xAA, 0xAA>>,
      <<0x55, 0x55, 0x55>>,
      <<0x00, 0x00, 0x00>>
    },
    dmg_green: {
      <<0xE0, 0xF8, 0xD0>>,
      <<0x88, 0xC0, 0x70>>,
      <<0x34, 0x68, 0x56>>,
      <<0x08, 0x18, 0x20>>
    }
  }

  @type palette :: :grayscale | :dmg_green

  @doc "Returns the native dimensions encoded by this module."
  @spec dimensions() :: {160, 144}
  def dimensions, do: {@width, @height}

  @doc "Returns the supported output-palette names."
  @spec palettes() :: [palette()]
  def palettes, do: [:grayscale, :dmg_green]

  @doc "Encodes a 160×144 DMG shade-index or CGB RGB24 frame as a truecolor PNG."
  @spec encode(binary(), keyword()) :: binary()
  def encode(frame, opts \\ []) when is_binary(frame) do
    palette = Keyword.get(opts, :palette, :dmg_green)
    format = Keyword.get_lazy(opts, :pixel_format, fn -> infer_format(frame) end)
    rgb = to_rgb(frame, format, palette)
    encode_rgb(@width, @height, rgb)
  end

  @doc "Encodes an arbitrary positive-sized RGB24 image using the supported PNG subset."
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

  @doc "Converts a native shade-index frame to RGB24 with the selected palette."
  @spec to_rgb(binary(), palette()) :: binary()
  def to_rgb(frame, palette) when is_binary(frame), do: to_rgb(frame, :dmg_shade_index, palette)

  @doc "Converts the selected native frame format to RGB24."
  @spec to_rgb(binary(), :dmg_shade_index | :rgb24, palette()) :: binary()
  def to_rgb(frame, :rgb24, _palette) when byte_size(frame) == @rgb_frame_bytes, do: frame

  def to_rgb(frame, :rgb24, _palette) when is_binary(frame) do
    raise ArgumentError, "expected #{@rgb_frame_bytes} RGB24 bytes, got #{byte_size(frame)}"
  end

  def to_rgb(frame, :dmg_shade_index, palette) when is_binary(frame) do
    unless byte_size(frame) == @frame_bytes do
      raise ArgumentError,
            "expected #{@frame_bytes} shade-index bytes, got #{byte_size(frame)}"
    end

    lut =
      case @palettes do
        %{^palette => lut} -> lut
        _other -> raise ArgumentError, "unsupported DMG palette: #{inspect(palette)}"
      end

    for <<shade <- frame>>, into: <<>> do
      if shade <= 3,
        do: elem(lut, shade),
        else: raise(ArgumentError, "invalid DMG shade index: #{shade}")
    end
  end

  defp infer_format(frame) when byte_size(frame) == @frame_bytes, do: :dmg_shade_index
  defp infer_format(frame) when byte_size(frame) == @rgb_frame_bytes, do: :rgb24

  defp infer_format(frame) do
    raise ArgumentError,
          "expected #{@frame_bytes} DMG bytes or #{@rgb_frame_bytes} RGB24 bytes, got #{byte_size(frame)}"
  end

  @doc "Decodes native-sized PNGs produced by `encode/2`; intended for tests and inspection."
  @spec decode(binary()) :: {160, 144, binary()}
  def decode(png) do
    {@width, @height, rgb} = decode_rgb(png)
    {@width, @height, rgb}
  end

  @doc "Decodes an arbitrary-sized PNG produced by this module."
  @spec decode_rgb(binary()) :: {pos_integer(), pos_integer(), binary()}
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

    rgb =
      for <<0, row::binary-size(^stride) <- raw>>, into: <<>>, do: row

    {width, height, rgb}
  end

  @doc "Returns bytes following the validated PNG IEND chunk without scanning payload data."
  @spec trailing_data(binary()) :: {:ok, binary()} | {:error, :invalid_png}
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
    unless valid_dimensions?(width, height) do
      raise ArgumentError, "PNG dimensions exceed limit"
    end
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
