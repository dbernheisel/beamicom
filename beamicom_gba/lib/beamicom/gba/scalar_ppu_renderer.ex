defmodule Beamicom.GBA.ScalarPPURenderer do
  @moduledoc "Scalar reference renderer for Game Boy Advance video modes."

  @behaviour Beamicom.GBA.PPURenderer

  import Bitwise

  alias Beamicom.GBA.PPU.ColorCorrection

  @pixels 240 * 160
  @frame_bytes @pixels * 2
  @vram_bytes 96 * 1024
  @palette_bytes 1024
  @oam_bytes 1024

  @impl true
  def render_mode0(vram, palette, oam, registers)
      when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
             byte_size(palette) >= @palette_bytes and is_binary(oam) and
             byte_size(oam) >= @oam_bytes and is_map(registers),
      do: render_tiled_modes(vram, palette, oam, registers)

  @impl true
  def render_mode1(vram, palette, oam, registers)
      when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
             byte_size(palette) >= @palette_bytes and is_binary(oam) and
             byte_size(oam) >= @oam_bytes and is_map(registers),
      do: render_tiled_modes(vram, palette, oam, registers)

  defp render_tiled_modes(vram, palette, oam, registers) do
    objects = objects(oam, registers.dispcnt, false)

    for y <- 0..159,
        line_registers = scanline_registers(registers, y),
        x <- 0..239,
        into: <<>> do
      window_control =
        window_control(
          line_registers,
          x,
          y,
          enabled?(line_registers.dispcnt, 15) and
            object_window_pixel?(objects, vram, palette, x, y)
        )

      object =
        if enabled?(line_registers.dispcnt, 12) and enabled?(window_control, 4),
          do: object_pixel(objects, vram, palette, x, y)

      vram
      |> tiled_layers(palette, line_registers, window_control, x, y)
      |> composite_pixel(object, line_registers, enabled?(window_control, 5))
      |> ColorCorrection.rgb24()
    end
  end

  @impl true
  def render_mode3(vram, palette, oam, registers)
      when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
             byte_size(palette) >= @palette_bytes and is_binary(oam) and
             byte_size(oam) >= @oam_bytes and is_map(registers) do
    objects = objects(oam, registers.dispcnt, true)

    for y <- 0..159,
        line_registers = scanline_registers(registers, y),
        x <- 0..239,
        into: <<>> do
      window_control =
        window_control(
          line_registers,
          x,
          y,
          enabled?(line_registers.dispcnt, 15) and
            object_window_pixel?(objects, vram, palette, x, y)
        )

      background_priority = elem(line_registers.bgcnt, 2) &&& 0x3
      background = little16(vram, (y * 240 + x) * 2)

      background_layer =
        if enabled?(window_control, 2),
          do: [{background_priority, 3, background, 2, false}],
          else: []

      object =
        if enabled?(line_registers.dispcnt, 12) and enabled?(window_control, 4),
          do: object_pixel(objects, vram, palette, x, y)

      [backdrop_layer(palette), void_layer() | background_layer]
      |> composite_pixel(object, line_registers, enabled?(window_control, 5))
      |> ColorCorrection.rgb24()
    end
  end

  @doc false
  def render_mode3(vram) when is_binary(vram) and byte_size(vram) >= @frame_bytes do
    for <<pixel::little-16 <- binary_part(vram, 0, @frame_bytes)>>,
      into: <<>>,
      do: ColorCorrection.rgb24(pixel)
  end

  defp mode0_layers(vram, palette, registers, window_control, x, y) do
    backgrounds =
      for layer <- 0..3,
          enabled?(registers.dispcnt, 8 + layer),
          enabled?(window_control, layer),
          pixel = background_pixel(vram, palette, registers, layer, x, y),
          pixel != :transparent,
          do: layer_entry(pixel)

    [void_layer(), backdrop_layer(palette) | backgrounds]
  end

  defp scanline_registers(registers, y) do
    affine = Map.get(registers, :bg_affine, affine_defaults())

    registers
    |> Map.put(
      :dispcnt,
      scanline_value(registers, :scanline_dispcnt, y, Map.fetch!(registers, :dispcnt))
    )
    |> Map.put(
      :bgcnt,
      scanline_value(registers, :scanline_bgcnt, y, Map.fetch!(registers, :bgcnt))
    )
    |> Map.put(
      :bghofs,
      scanline_value(registers, :scanline_bghofs, y, Map.fetch!(registers, :bghofs))
    )
    |> Map.put(
      :bgvofs,
      scanline_value(registers, :scanline_bgvofs, y, Map.fetch!(registers, :bgvofs))
    )
    |> Map.put(
      :bg_affine,
      scanline_value(registers, :scanline_bg_affine, y, effective_affine(affine, y))
    )
    |> Map.put(
      :display_effects,
      scanline_value(
        registers,
        :scanline_display_effects,
        y,
        Map.get(registers, :display_effects, display_effect_defaults())
      )
    )
  end

  defp scanline_value(registers, field, y, fallback) do
    case Map.get(registers, field) do
      scanlines when is_tuple(scanlines) and tuple_size(scanlines) == 160 ->
        elem(scanlines, y)

      _missing ->
        fallback
    end
  end

  defp effective_affine(affine, y) do
    affine
    |> Tuple.to_list()
    |> Enum.map(fn {pa, pb, pc, pd, reference_x, reference_y} ->
      {pa, pb, pc, pd, reference_x + signed16(pb) * y &&& 0x0FFF_FFFF,
       reference_y + signed16(pd) * y &&& 0x0FFF_FFFF}
    end)
    |> List.to_tuple()
  end

  defp affine_defaults,
    do: {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}}

  defp display_effect_defaults, do: List.duplicate(0, 11) |> List.to_tuple()

  defp window_control(registers, x, y, object_window?) do
    dispcnt = registers.dispcnt

    if (dispcnt &&& 0xE000) == 0 do
      0x3F
    else
      effects = Map.get(registers, :display_effects, display_effect_defaults())
      inside = elem(effects, 4)
      outside = elem(effects, 5)

      cond do
        enabled?(dispcnt, 13) and
            inside_window?(x, y, elem(effects, 0), elem(effects, 2)) ->
          inside &&& 0x3F

        enabled?(dispcnt, 14) and
            inside_window?(x, y, elem(effects, 1), elem(effects, 3)) ->
          inside >>> 8 &&& 0x3F

        enabled?(dispcnt, 15) and object_window? ->
          outside >>> 8 &&& 0x3F

        true ->
          outside &&& 0x3F
      end
    end
  end

  defp inside_window?(x, y, horizontal, vertical),
    do: inside_window_axis?(x, horizontal, 240) and inside_window_axis?(y, vertical, 160)

  defp inside_window_axis?(coordinate, limits, extent) do
    first = limits >>> 8 &&& 0xFF
    last = limits &&& 0xFF

    cond do
      last > extent -> true
      first < last -> coordinate >= first and coordinate < last
      first > last -> coordinate >= first or coordinate < last
      true -> false
    end
  end

  defp tiled_layers(vram, palette, registers, window_control, x, y) do
    case registers.dispcnt &&& 0x7 do
      0 -> mode0_layers(vram, palette, registers, window_control, x, y)
      1 -> mode1_layers(vram, palette, registers, window_control, x, y)
      _unsupported_mode -> [void_layer(), backdrop_layer(palette)]
    end
  end

  defp mode1_layers(vram, palette, registers, window_control, x, y) do
    backgrounds =
      for layer <- 0..1,
          enabled?(registers.dispcnt, 8 + layer),
          enabled?(window_control, layer),
          pixel = background_pixel(vram, palette, registers, layer, x, y),
          pixel != :transparent,
          do: layer_entry(pixel)

    backgrounds =
      if enabled?(registers.dispcnt, 10) and enabled?(window_control, 2) do
        case affine_background_pixel(vram, palette, registers, 2, x, y) do
          :transparent -> backgrounds
          pixel -> [layer_entry(pixel) | backgrounds]
        end
      else
        backgrounds
      end

    [void_layer(), backdrop_layer(palette) | backgrounds]
  end

  defp layer_entry({priority, layer, color}),
    do: {priority, layer + 1, color, layer, false}

  defp backdrop_layer(palette), do: {4, 6, palette_color(palette, 0), 5, false}
  defp void_layer, do: {5, 7, 0, 6, false}

  defp composite_pixel(layers, nil, registers, effects_enabled?),
    do: composite_layers(layers, registers, effects_enabled?)

  defp composite_pixel(layers, {priority, color, graphics_mode}, registers, effects_enabled?) do
    composite_layers(
      [{priority, 0, color, 4, graphics_mode == 1} | layers],
      registers,
      effects_enabled?
    )
  end

  defp composite_layers(layers, registers, effects_enabled?) do
    [first, second | _rest] =
      Enum.sort_by(layers, fn {priority, order, _, _, _} -> {priority, order} end)

    {_priority, _order, first_color, first_source, semi_transparent?} = first
    {_priority, _order, second_color, second_source, _semi_transparent?} = second

    color_effect(
      first_color,
      first_source,
      second_color,
      second_source,
      registers,
      semi_transparent?,
      effects_enabled?
    )
  end

  defp objects(_oam, dispcnt, _bitmap_mode?) when (dispcnt &&& 0x1000) == 0, do: []

  defp objects(oam, dispcnt, bitmap_mode?) do
    one_dimensional? = enabled?(dispcnt, 6)

    0..127
    |> Enum.map(fn index -> object(oam, index, one_dimensional?, bitmap_mode?) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn object -> {object.priority, object.index} end)
  end

  defp object(oam, index, one_dimensional?, bitmap_mode?) do
    offset = index * 8
    attr0 = little16(oam, offset)
    attr1 = little16(oam, offset + 2)
    attr2 = little16(oam, offset + 4)
    object_mode = attr0 >>> 8 &&& 0x3
    graphics_mode = attr0 >>> 10 &&& 0x3
    shape = attr0 >>> 14
    size = attr1 >>> 14
    {width, height} = object_dimensions(shape, size)
    tile = attr2 &&& 0x3FF

    if object_mode != 2 and graphics_mode < 3 and width > 0 and
         (not bitmap_mode? or tile >= 512) do
      raw_x = attr1 &&& 0x1FF
      raw_y = attr0 &&& 0xFF
      base_x = if raw_x >= 256, do: raw_x - 512, else: raw_x
      affine? = object_mode in [1, 3]
      double_size? = object_mode == 3
      display_width = if double_size?, do: width * 2, else: width
      display_height = if double_size?, do: height * 2, else: height
      base_y = if raw_y + display_height > 256, do: raw_y - 256, else: raw_y
      x = base_x
      y = base_y

      if x < 240 and x + display_width > 0 and y < 160 and y + display_height > 0 do
        %{
          index: index,
          x: x,
          y: y,
          width: width,
          height: height,
          display_width: display_width,
          display_height: display_height,
          tile: tile,
          eight_bit?: enabled?(attr0, 13),
          horizontal_flip?: not affine? and enabled?(attr1, 12),
          vertical_flip?: not affine? and enabled?(attr1, 13),
          affine_matrix: if(affine?, do: object_affine_matrix(oam, attr1), else: nil),
          graphics_mode: graphics_mode,
          priority: attr2 >>> 10 &&& 0x3,
          palette_bank: attr2 >>> 12,
          one_dimensional?: one_dimensional?
        }
      end
    end
  end

  defp object_pixel(objects, vram, palette, x, y) do
    Enum.find_value(objects, fn object ->
      if object.graphics_mode < 2, do: object_color_at(object, vram, palette, x, y)
    end)
  end

  defp object_window_pixel?(objects, vram, palette, x, y) do
    Enum.any?(objects, fn object ->
      object.graphics_mode == 2 and not is_nil(object_color_at(object, vram, palette, x, y))
    end)
  end

  defp object_color_at(object, vram, palette, x, y) do
    local_x = x - object.x
    local_y = y - object.y

    if local_x >= 0 and local_x < object.display_width and local_y >= 0 and
         local_y < object.display_height do
      object_color(object, vram, palette, local_x, local_y)
    end
  end

  defp object_color(object, vram, palette, local_x, local_y) do
    {pixel_x, pixel_y} = object_source_coordinates(object, local_x, local_y)

    if pixel_x < 0 or pixel_x >= object.width or pixel_y < 0 or pixel_y >= object.height do
      nil
    else
      object_source_color(object, vram, palette, pixel_x, pixel_y)
    end
  end

  defp object_source_coordinates(%{affine_matrix: nil} = object, local_x, local_y) do
    pixel_x = if object.horizontal_flip?, do: object.width - local_x - 1, else: local_x
    pixel_y = if object.vertical_flip?, do: object.height - local_y - 1, else: local_y
    {pixel_x, pixel_y}
  end

  defp object_source_coordinates(object, local_x, local_y) do
    {pa, pb, pc, pd} = object.affine_matrix
    centered_x = local_x - div(object.display_width, 2)
    centered_y = local_y - div(object.display_height, 2)

    pixel_x =
      ((pa * centered_x + pb * centered_y) >>> 8) + div(object.width, 2)

    pixel_y =
      ((pc * centered_x + pd * centered_y) >>> 8) + div(object.height, 2)

    {pixel_x, pixel_y}
  end

  defp object_source_color(object, vram, palette, pixel_x, pixel_y) do
    tile_x = div(pixel_x, 8)
    tile_y = div(pixel_y, 8)
    units_per_tile = if object.eight_bit?, do: 2, else: 1

    row_units =
      if object.one_dimensional?, do: div(object.width, 8) * units_per_tile, else: 32

    base_tile = if object.eight_bit?, do: object.tile &&& 0x3FE, else: object.tile
    tile = base_tile + tile_y * row_units + tile_x * units_per_tile
    in_tile_x = rem(pixel_x, 8)
    in_tile_y = rem(pixel_y, 8)

    color_index =
      if object.eight_bit? do
        vram_byte(vram, 0x10_000 + tile * 32 + in_tile_y * 8 + in_tile_x)
      else
        byte =
          vram_byte(vram, 0x10_000 + tile * 32 + in_tile_y * 4 + div(in_tile_x, 2))

        if rem(in_tile_x, 2) == 0, do: byte &&& 0xF, else: byte >>> 4
      end

    if color_index == 0 do
      nil
    else
      palette_index =
        if object.eight_bit?, do: color_index, else: object.palette_bank * 16 + color_index

      {object.priority, palette_color(palette, 256 + palette_index), object.graphics_mode}
    end
  end

  defp object_affine_matrix(oam, attr1) do
    base = (attr1 >>> 9 &&& 0x1F) * 32

    {signed16(little16(oam, base + 6)), signed16(little16(oam, base + 14)),
     signed16(little16(oam, base + 22)), signed16(little16(oam, base + 30))}
  end

  defp color_effect(
         first,
         first_source,
         second,
         second_source,
         registers,
         semi_transparent?,
         effects_enabled?
       ) do
    effects =
      Map.get(registers, :display_effects, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})

    control = elem(effects, 8)
    alpha = elem(effects, 9)
    brightness = min(elem(effects, 10) &&& 0x1F, 16)
    target1? = enabled?(control, first_source)
    target2? = enabled?(control, 8 + second_source)
    mode = control >>> 6 &&& 0x3

    cond do
      effects_enabled? and target2? and
          (semi_transparent? or (target1? and mode == 1)) ->
        blend(first, second, min(alpha &&& 0x1F, 16), min(alpha >>> 8 &&& 0x1F, 16))

      effects_enabled? and target1? and mode == 2 ->
        brighten(first, brightness)

      effects_enabled? and target1? and mode == 3 ->
        darken(first, brightness)

      true ->
        first
    end
  end

  defp blend(first, second, eva, evb) do
    components(first, fn component, shift ->
      second_component = second >>> shift &&& 0x1F
      min(31, (component * eva + second_component * evb) >>> 4)
    end)
  end

  defp brighten(color, coefficient),
    do:
      components(color, fn component, _shift ->
        component + (((31 - component) * coefficient) >>> 4)
      end)

  defp darken(color, coefficient),
    do:
      components(color, fn component, _shift -> component - ((component * coefficient) >>> 4) end)

  defp components(color, transform) do
    transform.(color &&& 0x1F, 0) |||
      transform.(color >>> 5 &&& 0x1F, 5) <<< 5 |||
      transform.(color >>> 10 &&& 0x1F, 10) <<< 10
  end

  defp object_dimensions(0, 0), do: {8, 8}
  defp object_dimensions(0, 1), do: {16, 16}
  defp object_dimensions(0, 2), do: {32, 32}
  defp object_dimensions(0, 3), do: {64, 64}
  defp object_dimensions(1, 0), do: {16, 8}
  defp object_dimensions(1, 1), do: {32, 8}
  defp object_dimensions(1, 2), do: {32, 16}
  defp object_dimensions(1, 3), do: {64, 32}
  defp object_dimensions(2, 0), do: {8, 16}
  defp object_dimensions(2, 1), do: {8, 32}
  defp object_dimensions(2, 2), do: {16, 32}
  defp object_dimensions(2, 3), do: {32, 64}
  defp object_dimensions(_shape, _size), do: {0, 0}

  defp background_pixel(vram, palette, registers, layer, x, y) do
    control = elem(registers.bgcnt, layer)
    horizontal = elem(registers.bghofs, layer)
    vertical = elem(registers.bgvofs, layer)
    {width, height} = background_size(control >>> 14)
    background_x = rem(x + horizontal, width)
    background_y = rem(y + vertical, height)
    tile_x = div(background_x, 8)
    tile_y = div(background_y, 8)
    blocks_wide = div(width, 256)
    screen_block = (control >>> 8 &&& 0x1F) + div(tile_y, 32) * blocks_wide + div(tile_x, 32)
    entry_index = rem(tile_y, 32) * 32 + rem(tile_x, 32)
    entry_offset = screen_block * 0x800 + entry_index * 2
    entry = little16(vram, entry_offset)
    pixel_x = if enabled?(entry, 10), do: 7 - rem(background_x, 8), else: rem(background_x, 8)
    pixel_y = if enabled?(entry, 11), do: 7 - rem(background_y, 8), else: rem(background_y, 8)
    tile = entry &&& 0x3FF
    character_base = (control >>> 2 &&& 0x3) * 0x4000
    priority = control &&& 0x3

    if enabled?(control, 7) do
      color_index = vram_byte(vram, character_base + tile * 64 + pixel_y * 8 + pixel_x)
      background_color(palette, priority, layer, color_index)
    else
      byte = vram_byte(vram, character_base + tile * 32 + pixel_y * 4 + div(pixel_x, 2))
      color_index = if rem(pixel_x, 2) == 0, do: byte &&& 0xF, else: byte >>> 4
      palette_bank = entry >>> 12
      background_color(palette, priority, layer, palette_bank * 16 + color_index, color_index)
    end
  end

  defp affine_background_pixel(vram, palette, registers, layer, x, _y) do
    control = elem(registers.bgcnt, layer)
    {pa, _pb, pc, _pd, reference_x, reference_y} = elem(registers.bg_affine, layer - 2)
    size = 128 <<< (control >>> 14)
    transformed_x = (signed28(reference_x) + signed16(pa) * x) >>> 8
    transformed_y = (signed28(reference_y) + signed16(pc) * x) >>> 8
    wraps? = enabled?(control, 13)

    if wraps? or
         (transformed_x >= 0 and transformed_x < size and transformed_y >= 0 and
            transformed_y < size) do
      background_x = Integer.mod(transformed_x, size)
      background_y = Integer.mod(transformed_y, size)
      tiles_wide = div(size, 8)
      screen_base = (control >>> 8 &&& 0x1F) * 0x800

      tile =
        vram_byte(vram, screen_base + div(background_y, 8) * tiles_wide + div(background_x, 8))

      character_base = (control >>> 2 &&& 0x3) * 0x4000

      color_index =
        vram_byte(
          vram,
          character_base + tile * 64 + rem(background_y, 8) * 8 + rem(background_x, 8)
        )

      background_color(palette, control &&& 0x3, layer, color_index)
    else
      :transparent
    end
  end

  defp background_color(_palette, _priority, _layer, 0), do: :transparent

  defp background_color(palette, priority, layer, color_index),
    do: {priority, layer, palette_color(palette, color_index)}

  defp background_color(_palette, _priority, _layer, _palette_index, 0), do: :transparent

  defp background_color(palette, priority, layer, palette_index, _color_index),
    do: {priority, layer, palette_color(palette, palette_index)}

  defp background_size(0), do: {256, 256}
  defp background_size(1), do: {512, 256}
  defp background_size(2), do: {256, 512}
  defp background_size(3), do: {512, 512}

  defp palette_color(palette, index), do: little16(palette, index * 2)

  defp little16(binary, offset),
    do: :binary.at(binary, offset) ||| :binary.at(binary, offset + 1) <<< 8

  defp vram_byte(vram, offset) do
    offset = rem(offset, 0x20_000)
    offset = if offset >= 0x18_000, do: offset - 0x8_000, else: offset
    :binary.at(vram, offset)
  end

  defp signed16(value) when value >= 0x8000, do: value - 0x1_0000
  defp signed16(value), do: value

  defp signed28(value) when value >= 0x0800_0000, do: value - 0x1000_0000
  defp signed28(value), do: value

  defp enabled?(value, bit), do: (value &&& 1 <<< bit) != 0
end
