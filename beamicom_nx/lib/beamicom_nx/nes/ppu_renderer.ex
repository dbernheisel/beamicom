defmodule BeamicomNx.NES.PPURenderer do
  @moduledoc """
  Frame-wide NES pixel compositor.

  The native PPU captures mapper-resolved tile rows and evaluated sprites at the
  correct scanline. This module performs only the regular 240 by 256 background
  decode, sprite priority, and RGB palette expansion in one compiled EXLA call.
  """

  import Nx.Defn

  @height 240
  @width 256
  @tiles 33
  @sprites 8
  @compiled_key {__MODULE__, :compiled}

  def render(lines, palette, grayscale, edge_mask) when length(lines) == @height do
    {lo, hi, attr, fine_x, mask, sx, slo, shi, sattr, svalid} = pack(lines)

    args = [
      tensor(lo, {@height, @tiles}),
      tensor(hi, {@height, @tiles}),
      tensor(attr, {@height, @tiles}),
      tensor(fine_x, {@height, 1}),
      tensor(mask, {@height, 1}),
      tensor(sx, {@height, @sprites}),
      tensor(slo, {@height, @sprites}),
      tensor(shi, {@height, @sprites}),
      tensor(sattr, {@height, @sprites}),
      tensor(svalid, {@height, @sprites}),
      tensor(palette, {32}),
      tensor(Beamicom.NES.Palette.master_binary(), {64, 3}),
      Nx.tensor(if(grayscale, do: 0x30, else: 0x3F), type: :u8),
      Nx.tensor(edge_mask, type: :u8)
    ]

    {pixels, rgb} = compiled(args) |> apply(args)
    {Nx.to_binary(pixels), Nx.to_binary(rgb)}
  end

  defn compose(
         lo,
         hi,
         attr,
         fine_x,
         mask,
         sx,
         slo,
         shi,
         sattr,
         svalid,
         palette,
         master,
         color_mask,
         edge_mask
       ) do
    x = Nx.iota({@height, @width}, axis: 1, type: :s32)
    source_x = x + Nx.as_type(fine_x, :s32)
    tile = Nx.quotient(source_x, 8)
    bit = 7 - band(source_x, 7)

    bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
    bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
    bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
    pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)

    bg =
      Nx.select(
        pattern == 0 or band(mask, 8) == 0 or (x < 8 and band(mask, 2) == 0),
        0,
        bg_attr * 4 + pattern
      )

    # Each evaluated sprite contributes only eight pixels. Scatter those 15,360
    # candidates in reverse priority order so earlier OAM entries overwrite later
    # ones. Column 256 is a throwaway sink for transparent or clipped candidates.
    sprite = Nx.broadcast(0, {@height, @width + 1})

    sprite = scatter_sprite(sprite, 7, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 6, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 5, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 4, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 3, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 2, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 1, mask, sx, slo, shi, sattr, svalid)
    sprite = scatter_sprite(sprite, 0, mask, sx, slo, shi, sattr, svalid)

    sprite = Nx.slice_along_axis(sprite, 0, @width, axis: 1)
    sprite_addr = band(sprite, 0x3F)
    sprite_front = band(sprite, 0x40) != 0
    visible = sprite_addr != 0

    pixels = Nx.select(visible and (bg == 0 or sprite_front), sprite_addr, bg) |> Nx.as_type(:u8)
    colors = Nx.take(palette, pixels) |> band(color_mask)
    rgb = Nx.take(master, colors)
    in_picture = x >= edge_mask and x < @width - edge_mask

    rgb =
      in_picture
      |> Nx.new_axis(2)
      |> Nx.broadcast({@height, @width, 3})
      |> Nx.select(rgb, 0)
      |> Nx.as_type(:u8)

    {pixels, rgb}
  end

  defnp scatter_sprite(pixels, rank, mask, sx, slo, shi, sattr, svalid) do
    rows = Nx.iota({@height, 8}, axis: 0, type: :s32)
    subpixel = Nx.iota({@height, 8}, axis: 1, type: :s32)
    x = Nx.new_axis(Nx.as_type(sx[[.., rank]], :s32), 1) + subpixel
    bit = 7 - subpixel
    lo = Nx.new_axis(Nx.as_type(slo[[.., rank]], :s32), 1)
    hi = Nx.new_axis(Nx.as_type(shi[[.., rank]], :s32), 1)
    pattern = bor(band(shr(lo, bit), 1), band(shr(hi, bit), 1) * 2)
    attr = Nx.new_axis(Nx.as_type(sattr[[.., rank]], :s32), 1)
    line_mask = Nx.as_type(mask, :s32)

    visible =
      Nx.new_axis(svalid[[.., rank]] != 0, 1) and pattern != 0 and x < @width and
        band(line_mask, 16) != 0 and
        (x >= 8 or band(line_mask, 4) != 0)

    columns = Nx.select(visible, x, @width)
    indices = Nx.stack([rows, columns], axis: 2) |> Nx.reshape({@height * 8, 2})
    front = Nx.select(band(attr, 32) == 0, 0x40, 0)
    values = 16 + band(attr, 3) * 4 + pattern + front
    Nx.indexed_put(pixels, indices, Nx.reshape(values, {@height * 8}))
  end

  defp pack(lines) do
    Enum.reduce(lines, {[], [], [], [], [], [], [], [], [], []}, fn
      {lo, hi, attr, fine_x, mask, sx, slo, shi, sattr, svalid},
      {los, his, attrs, fine_xs, masks, sxs, slos, shis, sattrs, svalids} ->
        {
          [lo | los],
          [hi | his],
          [attr | attrs],
          [<<fine_x>> | fine_xs],
          [<<mask>> | masks],
          [sx | sxs],
          [slo | slos],
          [shi | shis],
          [sattr | sattrs],
          [svalid | svalids]
        }
    end)
    |> Tuple.to_list()
    |> Enum.map(fn values -> values |> Enum.reverse() |> IO.iodata_to_binary() end)
    |> List.to_tuple()
  end

  defp tensor(binary, shape), do: binary |> Nx.from_binary(:u8) |> Nx.reshape(shape)

  defp compiled(args) do
    case :persistent_term.get(@compiled_key, nil) do
      nil ->
        fun = EXLA.compile(&compose/14, Enum.map(args, &Nx.to_template/1), client: :host)
        :persistent_term.put(@compiled_key, fun)
        fun

      fun ->
        fun
    end
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
