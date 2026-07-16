defmodule Beamicom.NES.VisualCode do
  @moduledoc """
  Encode a binary payload as a slim border of B/W dots framing a large NES
  screenshot, producing a self-contained share image.

  Assumes a lossless channel (the PNG is shared as-is), so the geometry is fixed
  and decode is exact — the screenshot is a centered `@ss_scale`× upscale and each
  data bit is one `@dot`×`@dot` cell in the surrounding border, read in row-major
  order. A 13-byte header (`"BMIC"` + version + payload size + CRC32) lets decode
  find the payload length and reject a foreign or damaged image.

  ponytail: lossless-only. Surviving JPEG recompress or downscaling would need
  corner markers + a block-size sweep + ECC (see git history for that design).
  """

  @ss_w 256
  @ss_h 240
  @ss_scale 4
  @sw @ss_w * @ss_scale
  @sh @ss_h * @ss_scale
  # px per data cell; must divide @sw and @sh (both share the factor 64).
  @dot 2
  @sw_cells div(@sw, @dot)
  @sh_cells div(@sh, @dot)
  @header_magic "BMIC"
  @header_version 1
  @header_size 13

  @doc """
  Encode `payload` into a share image framing `screenshot_rgb` (NES native 256×240).
  Returns `{width, height, rgb}` where rgb is a `width*height*3` binary.
  """
  def encode(payload, screenshot_rgb, screenshot_w, screenshot_h)
      when screenshot_w == @ss_w and screenshot_h == @ss_h do
    data = build_header(payload) <> payload
    bits = for <<b::1 <- data>>, do: b

    t = bezel_cells(length(bits))
    grid_w = @sw_cells + 2 * t
    grid_h = @sh_cells + 2 * t
    img_w = grid_w * @dot
    img_h = grid_h * @dot

    cell_bits = border_cells(grid_w, grid_h, t) |> Enum.zip(bits) |> Map.new()

    rgb =
      for py <- 0..(img_h - 1), px <- 0..(img_w - 1), into: <<>> do
        pixel(px, py, t, cell_bits, screenshot_rgb)
      end

    {img_w, img_h, rgb}
  end

  @doc "Decode a share image produced by encode/4. Returns {:ok, payload} | {:error, reason}."
  def decode(rgb, img_w, img_h) do
    grid_w = div(img_w, @dot)
    grid_h = div(img_h, @dot)
    t = div(grid_w - @sw_cells, 2)

    cond do
      grid_w < @sw_cells or grid_h < @sh_cells ->
        {:error, :bad_geometry}

      div(grid_h - @sh_cells, 2) != t ->
        {:error, :bad_geometry}

      true ->
        rgb |> read_border(img_w, grid_w, grid_h, t) |> decode_payload()
    end
  end

  ## ---- geometry (shared by encode + decode) ----

  # Minimum uniform bezel thickness (in cells) whose border holds at least n_bits cells.
  defp bezel_cells(n_bits) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find(fn t ->
      (@sw_cells + 2 * t) * (@sh_cells + 2 * t) - @sw_cells * @sh_cells >= n_bits
    end)
  end

  # Border cells ({row, col}) in row-major reading order, screenshot region excluded.
  defp border_cells(grid_w, grid_h, t) do
    for r <- 0..(grid_h - 1), c <- 0..(grid_w - 1), not in_screenshot?(r, c, t), do: {r, c}
  end

  defp in_screenshot?(r, c, t) do
    r >= t and r < t + @sh_cells and c >= t and c < t + @sw_cells
  end

  ## ---- encode ----

  defp build_header(payload) do
    @header_magic <>
      <<@header_version::8, byte_size(payload)::32, :erlang.crc32(payload)::32>>
  end

  # 3 RGB bytes for pixel (px, py): screenshot pixel inside the frame, dot color outside.
  defp pixel(px, py, t, cell_bits, screenshot_rgb) do
    r = div(py, @dot)
    c = div(px, @dot)

    if in_screenshot?(r, c, t) do
      nx = div(px - t * @dot, @ss_scale)
      ny = div(py - t * @dot, @ss_scale)
      off = (ny * @ss_w + nx) * 3
      <<_::binary-size(^off), rr, gg, bb, _::binary>> = screenshot_rgb
      <<rr, gg, bb>>
    else
      if Map.get(cell_bits, {r, c}, 0) == 1, do: <<255, 255, 255>>, else: <<0, 0, 0>>
    end
  end

  ## ---- decode ----

  # Sample each border cell at its center → list of 0/1 in the same reading order.
  defp read_border(rgb, img_w, grid_w, grid_h, t) do
    half = div(@dot, 2)

    for r <- 0..(grid_h - 1), c <- 0..(grid_w - 1), not in_screenshot?(r, c, t) do
      px = c * @dot + half
      py = r * @dot + half
      off = (py * img_w + px) * 3
      <<_::binary-size(^off), luma, _::binary>> = rgb
      if luma >= 128, do: 1, else: 0
    end
  end

  defp decode_payload(cells) do
    with header when byte_size(header) == @header_size <-
           cells |> Enum.take(@header_size * 8) |> pack_bits(),
         <<@header_magic, @header_version::8, size::32, crc::32>> <- header,
         total = (@header_size + size) * 8,
         true <- length(cells) >= total,
         <<@header_magic, @header_version::8, ^size::32, ^crc::32, payload::binary-size(^size)>> <-
           cells |> Enum.take(total) |> pack_bits(),
         true <- :erlang.crc32(payload) == crc do
      {:ok, payload}
    else
      _ -> {:error, :undecodable}
    end
  end

  defp pack_bits(bits), do: for(b <- bits, into: <<>>, do: <<b::1>>)
end
