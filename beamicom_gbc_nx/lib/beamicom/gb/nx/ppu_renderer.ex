defmodule Beamicom.GB.Nx.PPURenderer do
  @moduledoc """
  Frame-wide DMG/CGB tile, window, sprite, priority, and palette renderer.

  The live PPU records compact mapper-timed tile-plane rows and the first ten
  selected objects at HBlank. One EXLA operation expands and composes all
  23,040 pixels at VBlank.
  """

  import Nx.Defn
  @behaviour Beamicom.GB.PPURenderer

  @height 144
  @width 160
  @tiles 21
  @sprites 10
  @layers_size @tiles * 3 * 2
  @sprites_offset @layers_size
  @control_offset @sprites_offset + @sprites * 5
  @dmg_row_size @control_offset + 7
  @cgb_row_size @control_offset + 4 + 64 * 3

  @impl true
  def prepare(model) when model in [:dmg, :cgb], do: nil

  @impl true
  def render(:dmg, lines, state) when length(lines) == @height do
    args = [tensor(IO.iodata_to_binary(lines), {@height, @dmg_row_size})]
    frame = compiled(:dmg, args) |> apply(args)
    {Nx.to_binary(frame), state}
  end

  def render(:cgb, lines, state) when length(lines) == @height do
    args = [tensor(IO.iodata_to_binary(lines), {@height, @cgb_row_size})]
    frame = compiled(:cgb, args) |> apply(args)
    {Nx.to_binary(frame), state}
  end

  defn compose_dmg(rows) do
    {background, window, sprites, control} = unpack(rows, @dmg_row_size)
    {bg_color, _bg_attrs} = layers(background, window, control)
    {object_color, object_attrs, occupied} = objects(sprites)

    lcdc = column(control, 0) |> Nx.broadcast({@height, @width})
    bg_color = Nx.select(band(lcdc, 1) != 0, bg_color, 0)
    bgp = column(control, 4) |> Nx.broadcast({@height, @width})
    obp0 = column(control, 5) |> Nx.broadcast({@height, @width})
    obp1 = column(control, 6) |> Nx.broadcast({@height, @width})
    bg = band(shr(bgp, bg_color * 2), 3)
    object_palette = Nx.select(band(object_attrs, 0x10) != 0, obp1, obp0)
    object = band(shr(object_palette, object_color * 2), 3)
    behind_background = band(object_attrs, 0x80) != 0 and bg_color != 0
    Nx.select(occupied and not behind_background, object, bg) |> Nx.as_type(:u8)
  end

  defn compose_cgb(rows) do
    {background, window, sprites, control} = unpack(rows, @cgb_row_size)
    {bg_color, bg_attrs} = layers(background, window, control)
    {object_color, object_attrs, occupied} = objects(sprites)

    palettes =
      rows[[.., (@control_offset + 4)..(@cgb_row_size - 1)]]
      |> Nx.reshape({@height, 64, 3})

    bg_index = band(bg_attrs, 7) * 4 + bg_color
    object_index = 32 + band(object_attrs, 7) * 4 + object_color
    bg = palette_gather(palettes, bg_index)
    object = palette_gather(palettes, object_index)
    lcdc = column(control, 0)

    priority =
      band(lcdc, 1) != 0 and bg_color != 0 and
        (band(bg_attrs, 0x80) != 0 or band(object_attrs, 0x80) != 0)

    visible = occupied and not priority
    visible = visible |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})
    Nx.select(visible, object, bg)
  end

  deftransformp unpack(rows, row_size) do
    background = rows[[.., 0..(@tiles * 3 - 1)]] |> Nx.reshape({@height, @tiles, 3})

    window =
      rows[[.., (@tiles * 3)..(@layers_size - 1)]]
      |> Nx.reshape({@height, @tiles, 3})

    sprites =
      rows[[.., @sprites_offset..(@control_offset - 1)]]
      |> Nx.reshape({@height, @sprites, 5})

    control = rows[[.., @control_offset..(row_size - 1)]]
    {background, window, sprites, control}
  end

  defnp layers(background, window, control) do
    x = Nx.iota({@height, @width}, axis: 1, type: :s32)
    fine = column(control, 1) |> Nx.as_type(:s32)
    {bg_color, bg_attrs} = tile_pixels(background, x + fine)

    wx = column(control, 3) |> Nx.as_type(:s32)
    window_x = wx - 7
    window_source = Nx.max(x - window_x, 0)
    {window_color, window_attrs} = tile_pixels(window, window_source)
    window_visible = column(control, 2) != 0 and x >= window_x

    {Nx.select(window_visible, window_color, bg_color),
     Nx.select(window_visible, window_attrs, bg_attrs)}
  end

  defnp tile_pixels(tiles, source_x) do
    tile_index = Nx.quotient(source_x, 8)
    pixel = band(source_x, 7)
    low = Nx.take_along_axis(tiles[[.., .., 0]], tile_index, axis: 1) |> Nx.as_type(:s32)
    high = Nx.take_along_axis(tiles[[.., .., 1]], tile_index, axis: 1) |> Nx.as_type(:s32)
    attrs = Nx.take_along_axis(tiles[[.., .., 2]], tile_index, axis: 1) |> Nx.as_type(:s32)
    bit = Nx.select(band(attrs, 0x20) != 0, pixel, 7 - pixel)
    color = bor(band(shr(low, bit), 1), band(shr(high, bit), 1) * 2)
    {color, attrs}
  end

  deftransformp objects(sprites) do
    x = Nx.iota({@height, @width}, axis: 1, type: :s32)
    color = Nx.broadcast(0, {@height, @width})
    attrs = Nx.broadcast(0, {@height, @width})

    {color, attrs} =
      Enum.reduce((@sprites - 1)..0//-1, {color, attrs}, fn index, {color, attrs} ->
        sprite = sprites[[.., index, ..]]
        left = Nx.subtract(Nx.as_type(column(sprite, 0), :s32), 8)
        low = sprite |> column(1) |> Nx.as_type(:s32) |> Nx.broadcast({@height, @width})
        high = sprite |> column(2) |> Nx.as_type(:s32) |> Nx.broadcast({@height, @width})

        sprite_attrs =
          sprite |> column(3) |> Nx.as_type(:s32) |> Nx.broadcast({@height, @width})

        valid = sprite |> column(4) |> Nx.not_equal(0) |> Nx.broadcast({@height, @width})
        source = Nx.subtract(x, left)
        safe_source = Nx.clip(source, 0, 7)

        bit =
          Nx.select(
            Nx.not_equal(band(sprite_attrs, 0x20), 0),
            safe_source,
            Nx.subtract(7, safe_source)
          )

        sprite_color =
          bor(band(shr(low, bit), 1), Nx.multiply(band(shr(high, bit), 1), 2))

        visible =
          Nx.logical_and(
            valid,
            Nx.logical_and(
              Nx.greater_equal(source, 0),
              Nx.logical_and(Nx.less(source, 8), Nx.not_equal(sprite_color, 0))
            )
          )

        {Nx.select(visible, sprite_color, color), Nx.select(visible, sprite_attrs, attrs)}
      end)

    {color, attrs, Nx.not_equal(color, 0)}
  end

  defnp palette_gather(palettes, indexes) do
    indexes = indexes |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})
    Nx.take_along_axis(palettes, indexes, axis: 1)
  end

  defnp(column(tensor, index), do: tensor[[.., index]] |> Nx.reshape({@height, 1}))
  defp tensor(binary, shape), do: binary |> Nx.from_binary(:u8) |> Nx.reshape(shape)

  defp compiled(kind, args) do
    key = {__MODULE__, kind, :raw_rows_compiled}

    case :persistent_term.get(key, nil) do
      nil ->
        function = if kind == :dmg, do: &compose_dmg/1, else: &compose_cgb/1
        compiled = EXLA.compile(function, Enum.map(args, &Nx.to_template/1), client: :host)
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
