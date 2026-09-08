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
    stride = @width * 3
    scanlines = for <<row::binary-size(^stride) <- rgb>>, into: <<>>, do: <<0, row::binary>>
    ihdr = <<@width::32, @height::32, 8, 2, 0, 0, 0>>

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

  @doc "Decodes PNGs produced by `encode/2`; intended for tests and inspection."
  @spec decode(binary()) :: {160, 144, binary()}
  def decode(@signature <> chunks) do
    {@width, @height, idat} = collect_chunks(chunks, nil, nil, [])
    stride = @width * 3

    rgb =
      idat
      |> :lists.reverse()
      |> IO.iodata_to_binary()
      |> :zlib.uncompress()
      |> then(fn raw ->
        for <<0, row::binary-size(^stride) <- raw>>, into: <<>>, do: row
      end)

    {@width, @height, rgb}
  end

  defp collect_chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         width,
         height,
         idat
       ) do
    unless :erlang.crc32(type <> data) == crc,
      do: raise(ArgumentError, "invalid PNG chunk CRC")

    case type do
      "IHDR" ->
        <<new_width::32, new_height::32, 8, 2, 0, 0, 0>> = data
        collect_chunks(rest, new_width, new_height, idat)

      "IDAT" ->
        collect_chunks(rest, width, height, [data | idat])

      "IEND" ->
        {width, height, idat}

      _other ->
        collect_chunks(rest, width, height, idat)
    end
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
end
