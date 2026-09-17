defmodule Beamicom.SNES.VisualCode do
  @moduledoc """
  Losslessly represents an SNES save payload as a visible dot-code border.

  The native 256×224 screenshot is centered and nearest-neighbor enlarged 4×
  to 1024×896. A uniform border of 2×2 pixel cells carries a versioned,
  CRC-protected payload. Black cells represent zero bits; cells in a dominant
  screenshot color represent one bits.
  """

  import Bitwise

  alias Beamicom.SNES.PNG

  @native_width 256
  @native_height 224
  @scale 4
  @screenshot_width @native_width * @scale
  @screenshot_height @native_height * @scale
  @dot 2
  @screenshot_cells_w div(@screenshot_width, @dot)
  @screenshot_cells_h div(@screenshot_height, @dot)
  @magic "BMSN"
  @version 1
  @header_size 13

  @doc "Encodes payload and native RGB24 screenshot into `{width, height, rgb}`."
  def encode(payload, screenshot_rgb)
      when is_binary(payload) and
             byte_size(screenshot_rgb) == @native_width * @native_height * 3 do
    unless byte_size(payload) <= max_payload_bytes() do
      raise ArgumentError, "share-image payload exceeds safe geometry capacity"
    end

    data = header(payload) <> payload
    bit_count = byte_size(data) * 8
    thickness = bezel_cells(bit_count)
    grid_width = @screenshot_cells_w + 2 * thickness
    grid_height = @screenshot_cells_h + 2 * thickness
    width = grid_width * @dot
    height = grid_height * @dot

    unless PNG.valid_dimensions?(width, height) do
      raise ArgumentError, "share-image payload exceeds safe geometry capacity"
    end

    on = dominant_color(screenshot_rgb)

    rgb =
      for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
        pixel(x, y, grid_width, thickness, data, bit_count, screenshot_rgb, on)
      end

    {width, height, rgb}
  end

  @doc "Decodes and validates a payload from a share-image RGB buffer."
  def decode(rgb, width, height)
      when is_binary(rgb) and is_integer(width) and is_integer(height) and
             byte_size(rgb) == width * height * 3 do
    grid_width = div(width, @dot)
    grid_height = div(height, @dot)
    thickness = div(grid_width - @screenshot_cells_w, 2)

    cond do
      rem(width, @dot) != 0 or rem(height, @dot) != 0 ->
        {:error, :bad_geometry}

      grid_width < @screenshot_cells_w or grid_height < @screenshot_cells_h ->
        {:error, :bad_geometry}

      thickness < 1 or div(grid_height - @screenshot_cells_h, 2) != thickness ->
        {:error, :bad_geometry}

      true ->
        rgb
        |> border_bits(width, grid_width, grid_height, thickness)
        |> decode_payload()
    end
  end

  def decode(_rgb, _width, _height), do: {:error, :bad_geometry}

  @doc "Classifies the visible border marker without decoding its payload."
  def classify(rgb, width, height)
      when is_binary(rgb) and is_integer(width) and is_integer(height) and
             byte_size(rgb) == width * height * 3 do
    with {:ok, {_left, _top, @screenshot_width, @screenshot_height}} <-
           screenshot_rect(width, height) do
      grid_width = div(width, @dot)
      grid_height = div(height, @dot)
      thickness = div(grid_width - @screenshot_cells_w, 2)

      marker =
        rgb
        |> border_bits(width, grid_width, grid_height, thickness)
        |> Enum.take(byte_size(@magic) * 8)
        |> pack_bits()

      if marker == @magic, do: :snes, else: :not_snes
    end
  end

  def classify(_rgb, _width, _height), do: {:error, :bad_geometry}

  @doc "Returns the centered 4× screenshot rectangle for valid share-image geometry."
  def screenshot_rect(width, height) do
    horizontal = width - @screenshot_width
    vertical = height - @screenshot_height

    if horizontal >= 4 and horizontal == vertical and rem(horizontal, 4) == 0 do
      {:ok, {div(horizontal, 2), div(vertical, 2), @screenshot_width, @screenshot_height}}
    else
      {:error, :bad_geometry}
    end
  end

  @doc "Maximum payload whose bordered image fits the shared PNG safety limits."
  def max_payload_bytes do
    thickness = maximum_thickness()
    grid_width = @screenshot_cells_w + 2 * thickness
    grid_height = @screenshot_cells_h + 2 * thickness
    capacity_bits = grid_width * grid_height - @screenshot_cells_w * @screenshot_cells_h
    max(0, div(capacity_bits, 8) - @header_size)
  end

  defp header(payload),
    do: @magic <> <<@version::8, byte_size(payload)::32, :erlang.crc32(payload)::32>>

  defp bezel_cells(bit_count) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find(fn thickness ->
      (@screenshot_cells_w + 2 * thickness) * (@screenshot_cells_h + 2 * thickness) -
        @screenshot_cells_w * @screenshot_cells_h >= bit_count
    end)
  end

  defp maximum_thickness do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.take_while(fn thickness ->
      width = @screenshot_width + 2 * thickness * @dot
      height = @screenshot_height + 2 * thickness * @dot
      PNG.valid_dimensions?(width, height)
    end)
    |> List.last()
  end

  defp in_screenshot?(row, column, thickness) do
    row >= thickness and row < thickness + @screenshot_cells_h and column >= thickness and
      column < thickness + @screenshot_cells_w
  end

  defp pixel(x, y, grid_width, thickness, data, bit_count, screenshot, on) do
    row = div(y, @dot)
    column = div(x, @dot)

    if in_screenshot?(row, column, thickness) do
      native_x = div(x - thickness * @dot, @scale)
      native_y = div(y - thickness * @dot, @scale)
      binary_part(screenshot, (native_y * @native_width + native_x) * 3, 3)
    else
      bit_index = border_index(row, column, grid_width, thickness)

      if bit_index < bit_count and data_bit(data, bit_index) == 1,
        do: on,
        else: <<0, 0, 0>>
    end
  end

  defp border_index(row, column, grid_width, thickness) when row < thickness,
    do: row * grid_width + column

  defp border_index(row, column, grid_width, thickness)
       when row < thickness + @screenshot_cells_h do
    prior = thickness * grid_width + (row - thickness) * (2 * thickness)

    if column < thickness,
      do: prior + column,
      else: prior + thickness + column - thickness - @screenshot_cells_w
  end

  defp border_index(row, column, grid_width, thickness) do
    prior = thickness * grid_width + @screenshot_cells_h * (2 * thickness)
    prior + (row - thickness - @screenshot_cells_h) * grid_width + column
  end

  defp data_bit(data, index) do
    byte = :binary.at(data, div(index, 8))
    byte >>> (7 - rem(index, 8)) &&& 1
  end

  defp dominant_color(rgb) do
    counts =
      for <<r, g, b <- rgb>>, {r, g, b} != {0, 0, 0}, reduce: %{} do
        acc -> Map.update(acc, {r, g, b}, 1, &(&1 + 1))
      end

    case counts do
      map when map_size(map) == 0 -> <<255, 255, 255>>
      map -> map |> Enum.max_by(fn {_color, count} -> count end) |> elem(0) |> tuple_rgb()
    end
  end

  defp tuple_rgb({r, g, b}), do: <<r, g, b>>

  defp border_bits(rgb, width, grid_width, grid_height, thickness) do
    half = div(@dot, 2)

    Stream.flat_map(0..(grid_height - 1), fn row ->
      0..(grid_width - 1)
      |> Stream.reject(&in_screenshot?(row, &1, thickness))
      |> Stream.map(fn column ->
        x = column * @dot + half
        y = row * @dot + half
        <<r, g, b>> = binary_part(rgb, (y * width + x) * 3, 3)
        if r == 0 and g == 0 and b == 0, do: 0, else: 1
      end)
    end)
  end

  defp decode_payload(bits) do
    with header when byte_size(header) == @header_size <-
           bits |> Enum.take(@header_size * 8) |> pack_bits(),
         <<@magic, @version::8, size::32, crc::32>> <- header,
         true <- size <= max_payload_bytes(),
         total = (@header_size + size) * 8,
         <<@magic, @version::8, ^size::32, ^crc::32, payload::binary-size(^size)>> <-
           bits |> Enum.take(total) |> pack_bits(),
         true <- :erlang.crc32(payload) == crc do
      {:ok, payload}
    else
      _other -> {:error, :undecodable}
    end
  end

  defp pack_bits(bits), do: for(bit <- bits, into: <<>>, do: <<bit::1>>)
end
