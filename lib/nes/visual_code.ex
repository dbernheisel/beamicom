defmodule Beamicom.NES.VisualCode do
  @moduledoc """
  Robust block-code frame: encode a binary payload into a grid of B/W blocks around
  a centered NES screenshot. The frame survives JPEG recompress + uniform downscale
  to ~1280px via corner-marker-validated block-size recovery and majority-vote ECC.

  ## Robustness model

  The decoder never learns the original block size directly. It sweeps candidate
  block sizes (float), and for each one reconstructs the grid geometry from the
  received image dimensions, checks the four corner markers, and finally validates a
  CRC over the recovered payload. A uniform downscale changes only the block size, so
  a candidate close to `received_width / original_cols` recovers the grid; the CRC is
  the final arbiter, so a wrong candidate that happens to pass the corner check is
  still rejected.

  ponytail: assumes digital re-encode only (JPEG recompress + uniform downscale),
  no rotation/crop/photo-of-screen — no perspective correction. Add corner
  localization + homography if someone photographs a screen.

  ponytail: repetition + CRC, not Reed-Solomon. B/W blocks + majority vote is
  zero-dep and tuned to this channel. Upgrade to RS(GF256) if payload outgrows frame.
  """

  @block_sz 8
  @marker_sz 5
  @k 3
  # 256 * 2 / @block_sz, 240 * 2 / @block_sz
  @ss_bw 64
  @ss_bh 60
  @header_magic "BMIC"
  @header_version 1
  @header_size 13

  # Corner marker: 1=black, 0=white, indexed [row][col]
  @marker [
    [1, 1, 1, 1, 1],
    [1, 0, 0, 0, 1],
    [1, 0, 1, 0, 1],
    [1, 0, 0, 0, 1],
    [1, 1, 1, 1, 1]
  ]

  @doc """
  Encode `payload` into a visual block-code image framing `screenshot_rgb`.
  `screenshot_w` and `screenshot_h` must be the NES native size (256×240).
  Returns `{width, height, rgb}` where rgb is a `width*height*3` binary.
  """
  def encode(payload, screenshot_rgb, screenshot_w, screenshot_h)
      when screenshot_w == 256 and screenshot_h == 240 do
    data = build_header(payload) <> payload
    bits = for _ <- 1..@k, <<b::1 <- data>>, do: b

    {grid_cols, grid_rows, ss_row_start, ss_col_start} = grid_geometry(byte_size(payload))

    img_w = grid_cols * @block_sz
    img_h = grid_rows * @block_sz
    ss_disp = nn_upscale(screenshot_rgb, screenshot_w, screenshot_h, 512, 480)

    data_cells = data_cells(grid_cols, grid_rows, ss_row_start, ss_col_start)

    unless length(data_cells) >= length(bits) do
      raise "grid too small: #{length(data_cells)} cells for #{length(bits)} bits"
    end

    cell_bits = Enum.zip(data_cells, bits) |> Map.new()

    # Emit pixels in scanline order (row-major over pixels, not over blocks) so the
    # buffer is a valid width×height image for PNG.encode and the decoder's sampler.
    rgb =
      for py <- 0..(img_h - 1), px <- 0..(img_w - 1), into: <<>> do
        r = div(py, @block_sz)
        c = div(px, @block_sz)

        pixel_rgb(
          r,
          c,
          px,
          py,
          grid_cols,
          grid_rows,
          ss_row_start,
          ss_col_start,
          cell_bits,
          ss_disp
        )
      end

    {img_w, img_h, rgb}
  end

  @doc """
  Decode a `{rgb, width, height}` image produced by encode/4.
  Sweeps candidate block sizes (8.5 → 4.0 in 0.01 steps) and validates corner markers
  and a payload CRC to handle uniform downscales. Returns `{:ok, payload}` or
  `{:error, :undecodable}`.
  """
  def decode(rgb, img_w, img_h) do
    # 0.01 granularity: the recovery window for a ~2×NES image downscaled to 1280px
    # is only ~0.016px wide, so a coarser step (the original plan's 0.25/0.1) misses it.
    candidates = for i <- 0..450, do: Float.round(8.5 - i * 0.01, 2)

    Enum.find_value(candidates, {:error, :undecodable}, fn bsf ->
      try_decode(rgb, img_w, img_h, bsf)
    end)
  end

  ## ---- Private ----

  defp build_header(payload) do
    @header_magic <>
      <<@header_version::8, byte_size(payload)::32, :erlang.crc32(payload)::32>>
  end

  # Shared geometry: given payload_size, returns {grid_cols, grid_rows, ss_row_start,
  # ss_col_start}. Encode derives it from payload_size; decode derives the same grid
  # from the received image size, so the two only need to agree on cell layout.
  defp grid_geometry(payload_size) do
    total_bits = (@header_size + payload_size) * 8 * @k

    min_cols = @marker_sz * 2 + @ss_bw + 2
    min_rows = @marker_sz * 2 + @ss_bh + 2

    side = ceil(:math.sqrt(total_bits + @ss_bw * @ss_bh + 4 * @marker_sz * @marker_sz)) + 2

    grid_cols = max(side, min_cols)
    grid_rows = max(side, min_rows)

    ss_row_start = div(grid_rows - @ss_bh, 2)
    ss_col_start = div(grid_cols - @ss_bw, 2)

    {grid_cols, grid_rows, ss_row_start, ss_col_start}
  end

  # Returns list of {row, col} for data cells in reading order.
  defp data_cells(grid_cols, grid_rows, ss_row_start, ss_col_start) do
    for r <- 0..(grid_rows - 1),
        c <- 0..(grid_cols - 1),
        cell_type(r, c, grid_cols, grid_rows, ss_row_start, ss_col_start) == :data do
      {r, c}
    end
  end

  defp cell_type(r, c, grid_cols, grid_rows, ss_row_start, ss_col_start) do
    cond do
      corner?(r, c, grid_rows, grid_cols) -> :corner
      in_screenshot?(r, c, ss_row_start, ss_col_start) -> :screenshot
      true -> :data
    end
  end

  defp corner?(r, c, grid_rows, grid_cols) do
    m = @marker_sz - 1

    (r <= m and c <= m) or
      (r <= m and c >= grid_cols - @marker_sz) or
      (r >= grid_rows - @marker_sz and c <= m) or
      (r >= grid_rows - @marker_sz and c >= grid_cols - @marker_sz)
  end

  defp in_screenshot?(r, c, ss_row_start, ss_col_start) do
    r >= ss_row_start and r < ss_row_start + @ss_bh and
      c >= ss_col_start and c < ss_col_start + @ss_bw
  end

  # Return the 3 RGB bytes for pixel (px,py), which lives in cell (r,c).
  defp pixel_rgb(
         r,
         c,
         px,
         py,
         grid_cols,
         grid_rows,
         ss_row_start,
         ss_col_start,
         cell_bits,
         ss_disp
       ) do
    case cell_type(r, c, grid_cols, grid_rows, ss_row_start, ss_col_start) do
      :corner ->
        if marker_bit(r, c, grid_rows, grid_cols) == 1, do: <<0, 0, 0>>, else: <<255, 255, 255>>

      :screenshot ->
        # ss_disp is 512×480; map this pixel into it via its offset within the cell.
        sx = (c - ss_col_start) * @block_sz + rem(px, @block_sz)
        sy = (r - ss_row_start) * @block_sz + rem(py, @block_sz)
        off = (sy * 512 + sx) * 3
        <<_::binary-size(^off), rr, gg, bb, _::binary>> = ss_disp
        <<rr, gg, bb>>

      :data ->
        if Map.get(cell_bits, {r, c}, 0) == 1, do: <<255, 255, 255>>, else: <<0, 0, 0>>
    end
  end

  defp marker_bit(r, c, grid_rows, grid_cols) do
    m = @marker_sz - 1

    {mr, mc} =
      cond do
        r <= m and c <= m -> {r, c}
        r <= m and c >= grid_cols - @marker_sz -> {r, c - (grid_cols - @marker_sz)}
        r >= grid_rows - @marker_sz and c <= m -> {r - (grid_rows - @marker_sz), c}
        true -> {r - (grid_rows - @marker_sz), c - (grid_cols - @marker_sz)}
      end

    Enum.at(Enum.at(@marker, mr), mc)
  end

  defp nn_upscale(src, sw, sh, tw, th) do
    for dy <- 0..(th - 1), dx <- 0..(tw - 1), into: <<>> do
      sx = min(div(dx * sw, tw), sw - 1)
      sy = min(div(dy * sh, th), sh - 1)
      off = (sy * sw + sx) * 3
      <<_::binary-size(^off), r, g, b, _::binary>> = src
      <<r, g, b>>
    end
  end

  defp try_decode(rgb, img_w, img_h, bsf) do
    grid_cols = round(img_w / bsf)
    grid_rows = round(img_h / bsf)

    cond do
      grid_cols < @marker_sz * 2 + @ss_bw or grid_rows < @marker_sz * 2 + @ss_bh ->
        nil

      not verify_corners(rgb, img_w, img_h, grid_cols, grid_rows, bsf) ->
        nil

      true ->
        decode_payload(rgb, img_w, img_h, grid_cols, grid_rows, bsf)
    end
  end

  defp verify_corners(rgb, img_w, img_h, grid_cols, grid_rows, bsf) do
    Enum.all?(corner_positions(grid_cols, grid_rows), fn {base_r, base_c} ->
      Enum.all?(0..(@marker_sz - 1), fn mr ->
        Enum.all?(0..(@marker_sz - 1), fn mc ->
          # @marker uses 1=black; sample/4 uses 1=white, so invert to compare.
          expected_white = 1 - Enum.at(Enum.at(@marker, mr), mc)
          px = round((base_c + mc + 0.5) * bsf)
          py = round((base_r + mr + 0.5) * bsf)

          if px < img_w and py < img_h do
            sample(rgb, img_w, px, py) == expected_white
          else
            false
          end
        end)
      end)
    end)
  end

  defp corner_positions(grid_cols, grid_rows) do
    [
      {0, 0},
      {0, grid_cols - @marker_sz},
      {grid_rows - @marker_sz, 0},
      {grid_rows - @marker_sz, grid_cols - @marker_sz}
    ]
  end

  defp decode_payload(rgb, img_w, img_h, grid_cols, grid_rows, bsf) do
    cells = data_cell_bits(grid_cols, grid_rows, bsf, rgb, img_w, img_h)
    header_bits = @header_size * 8

    with header_bin when byte_size(header_bin) == @header_size <-
           cells |> Enum.take(header_bits) |> pack_bits(),
         <<@header_magic, @header_version::8, payload_size::32, expected_crc::32>> <- header_bin,
         total_bits = (@header_size + payload_size) * 8,
         true <- length(cells) >= total_bits * @k,
         voted = majority_vote(Enum.take(cells, total_bits * @k), total_bits),
         <<@header_magic, @header_version::8, ^payload_size::32, ^expected_crc::32,
           payload::binary-size(^payload_size)>> <- pack_bits(voted),
         true <- :erlang.crc32(payload) == expected_crc do
      {:ok, payload}
    else
      _ -> nil
    end
  end

  # Sample every data cell at its (float) block center → list of 0/1 in reading order.
  defp data_cell_bits(grid_cols, grid_rows, bsf, rgb, img_w, img_h) do
    ss_row_start = div(grid_rows - @ss_bh, 2)
    ss_col_start = div(grid_cols - @ss_bw, 2)

    for r <- 0..(grid_rows - 1),
        c <- 0..(grid_cols - 1),
        cell_type(r, c, grid_cols, grid_rows, ss_row_start, ss_col_start) == :data do
      px = min(round((c + 0.5) * bsf), img_w - 1)
      py = min(round((r + 0.5) * bsf), img_h - 1)
      sample(rgb, img_w, px, py)
    end
  end

  # 1 = white (luma high), 0 = black. Blocks are pure B/W so the R channel is enough.
  defp sample(rgb, img_w, px, py) do
    off = (py * img_w + px) * 3
    <<_::binary-size(^off), luma, _::binary>> = rgb
    if luma >= 128, do: 1, else: 0
  end

  # Majority vote across @k copies of `total_bits` bits each.
  defp majority_vote(bits, total_bits) do
    votes = Enum.chunk_every(bits, total_bits)

    for i <- 0..(total_bits - 1) do
      sum = Enum.reduce(votes, 0, fn copy, acc -> acc + Enum.at(copy, i, 0) end)
      if sum * 2 >= @k, do: 1, else: 0
    end
  end

  # Pack a list of 0/1 bits (MSB first) into a binary.
  defp pack_bits(bits), do: for(b <- bits, into: <<>>, do: <<b::1>>)
end
