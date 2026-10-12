if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.GBA.Nx.PPURenderer do
    @moduledoc "Fixed-shape Nx renderer for GBA tiled modes 0/1 and bitmap mode 3."

    @behaviour Beamicom.GBA.PPURenderer

    import Bitwise
    import Nx.Defn

    @pixels 240 * 160
    @vram_bytes 96 * 1024
    @palette_bytes 1024
    @oam_bytes 1024
    @frame_bytes @pixels * 2
    @object_buckets [16, 32, 64, 96, 128]
    @common_mode0_buckets [16, 32]
    @common_hybrid_buckets [16, 32]
    @common_mode_split 74
    @color_table Beamicom.GBA.PPU.ColorCorrection.rgb24_table()
    @hidden_object <<0xC200::little-signed-32, 0::little-signed-32, 0::little-signed-32,
                     255::little-signed-32, 0x0100::little-signed-32, 0::little-signed-32,
                     0::little-signed-32, 0x0100::little-signed-32>>
    @scanline_register_start 36
    @scanline_register_stride 36

    @impl true
    def render_mode0(vram, palette, oam, registers)
        when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
               byte_size(palette) >= @palette_bytes and is_binary(oam) and
               byte_size(oam) >= @oam_bytes and is_map(registers),
        do: render_tiled(vram, palette, oam, registers)

    @impl true
    def render_mode1(vram, palette, oam, registers)
        when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
               byte_size(palette) >= @palette_bytes and is_binary(oam) and
               byte_size(oam) >= @oam_bytes and is_map(registers),
        do: render_tiled(vram, palette, oam, registers)

    @doc "Compiles the common tiled renderer shapes before realtime execution."
    def warmup do
      blank_vram = :binary.copy(<<0>>, @vram_bytes)
      blank_palette = :binary.copy(<<0>>, @palette_bytes)

      registers = %{
        dispcnt: 0,
        bgcnt: {0, 0, 0, 0},
        bghofs: {0, 0, 0, 0},
        bgvofs: {0, 0, 0, 0},
        bg_affine: {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}}
      }

      vram = input(blank_vram, @vram_bytes)
      palette = input(blank_palette, @palette_bytes)
      register_values = register_input(registers)
      {mode0_y, boundary_y, mode1_y} = split_y_inputs(@common_mode_split)

      Enum.each(@common_mode0_buckets, fn bucket ->
        objects = warmup_objects(bucket)
        args = [vram, palette, objects, register_values]
        _frame = compiled_pure_mode0(args) |> apply(args) |> Nx.to_binary()
      end)

      Enum.each(@common_hybrid_buckets, fn bucket ->
        objects = warmup_objects(bucket)
        args = [vram, palette, objects, register_values]
        split_args = args ++ [mode0_y, boundary_y, mode1_y]
        _frame = compiled_mode01(split_args) |> apply(split_args) |> Nx.to_binary()
      end)

      :ok
    end

    defp warmup_objects(bucket) do
      [0xC200, 0, 0, 255, 0x0100, 0, 0, 0x0100]
      |> List.duplicate(bucket)
      |> List.duplicate(160)
      |> List.flatten()
      |> s32_input({160, bucket, 8})
    end

    @impl true
    def render_mode3(vram, palette, oam, registers)
        when is_binary(vram) and byte_size(vram) >= @vram_bytes and is_binary(palette) and
               byte_size(palette) >= @palette_bytes and is_binary(oam) and
               byte_size(oam) >= @oam_bytes and is_map(registers) do
      objects = object_input(oam, true)
      vram = input(vram, @vram_bytes)
      palette = cached_input(:palette, palette, @palette_bytes)

      register_values = register_input(registers)

      [vram, palette, objects, register_values]
      |> compiled_mode3()
      |> apply([vram, palette, objects, register_values])
      |> Nx.to_binary()
    end

    @doc false
    def render_mode3(vram) when is_binary(vram) and byte_size(vram) >= @frame_bytes do
      bytes = input(vram, @frame_bytes)

      [bytes]
      |> compiled_raw_mode3()
      |> apply([bytes])
      |> Nx.to_binary()
    end

    defp render_tiled(vram, palette, oam, registers) do
      objects = object_input(oam, false)
      vram = input(vram, @vram_bytes)
      palette = cached_input(:palette, palette, @palette_bytes)
      register_values = register_input(registers)
      base_args = [vram, palette, objects, register_values]

      {compiled, args} =
        case tiled_layout(registers) do
          :mode1 ->
            {compiled_mode1(base_args), base_args}

          :mode0 ->
            {compiled_pure_mode0(base_args), base_args}

          :mode0_no_bg2 ->
            {compiled_pure_mode0_no_bg2(base_args), base_args}

          {:mode0_mode1_boundary, split} ->
            {mode0_y, boundary_y, mode1_y} = split_y_inputs(split)
            args = base_args ++ [mode0_y, boundary_y, mode1_y]
            {compiled_mode01(args), args}

          :generic ->
            {compiled_mode0(base_args), base_args}
        end

      compiled |> apply(args) |> Nx.to_binary()
    end

    defn render_mode0_pixels(vram, palette, objects, registers) do
      render_tiled_pixels(vram, palette, objects, registers)
    end

    defn render_pure_mode0_pixels(vram, palette, objects, registers) do
      y = Nx.iota({160, 240}, axis: 0, type: :s32) |> Nx.flatten()
      render_mode0_region(vram, palette, objects, registers, y)
    end

    defn render_pure_mode0_no_bg2_pixels(vram, palette, objects, registers) do
      y = Nx.iota({160, 240}, axis: 0, type: :s32) |> Nx.flatten()
      render_mode0_no_bg2_region(vram, palette, objects, registers, y)
    end

    defn render_mode1_pixels(vram, palette, objects, registers) do
      render_mode1_tiled_pixels(vram, palette, objects, registers)
    end

    defn render_mode01_pixels(
           vram,
           palette,
           objects,
           registers,
           mode0_y,
           boundary_y,
           mode1_y
         ) do
      mode0 = render_mode0_region(vram, palette, objects, registers, mode0_y)
      boundary = render_tiled_region(vram, palette, objects, registers, boundary_y)
      mode1 = render_mode1_region(vram, palette, objects, registers, mode1_y)
      Nx.concatenate([mode0, boundary, mode1], axis: 0)
    end

    defnp render_tiled_pixels(vram, palette, objects, registers) do
      y = Nx.iota({160, 240}, axis: 0, type: :s32) |> Nx.flatten()
      render_tiled_region(vram, palette, objects, registers, y)
    end

    defnp render_tiled_region(vram, palette, objects, registers, y) do
      {_dispcnt, _x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode} = tiled_region_layers(vram, palette, objects, registers, y)

      composite_tiled_layers(
        registers,
        y,
        window_control,
        layers,
        object_valid?,
        object_priority,
        object_color,
        object_graphics_mode
      )
    end

    defnp tiled_region_layers(vram, palette, objects, registers, y) do
      pixel_count = Nx.axis_size(y, 0)
      x = Nx.iota({pixel_count}, type: :s32) |> Nx.remainder(240)
      dispcnt = scanline_register(registers, y, 0)
      mode = Nx.bitwise_and(dispcnt, 0x7)
      control0 = scanline_background_control(registers, y, 0)
      control1 = scanline_background_control(registers, y, 1)
      control2 = scanline_background_control(registers, y, 2)
      control3 = scanline_background_control(registers, y, 3)

      {object_valid?, object_priority, object_color, object_graphics_mode, object_window?} =
        object_layer(vram, palette, objects, dispcnt, 0, x, y)

      window_control = window_control(registers, dispcnt, x, y, object_window?)
      object_valid? = Nx.logical_and(object_valid?, bit_set?(window_control, 4))

      {key0, color0} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control0,
          scanline_register(registers, y, 5),
          scanline_register(registers, y, 9),
          x,
          y,
          0
        )

      {key1, color1} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control1,
          scanline_register(registers, y, 6),
          scanline_register(registers, y, 10),
          x,
          y,
          1
        )

      {regular_key2, regular_color2} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control2,
          scanline_register(registers, y, 7),
          scanline_register(registers, y, 11),
          x,
          y,
          2
        )

      {affine_key2, affine_color2} =
        affine_background_layer(
          vram,
          palette,
          dispcnt,
          control2,
          scanline_register(registers, y, 13),
          scanline_register(registers, y, 14),
          scanline_register(registers, y, 15),
          scanline_register(registers, y, 16),
          scanline_register(registers, y, 17),
          scanline_register(registers, y, 18),
          x,
          y,
          2
        )

      {key3, color3} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control3,
          scanline_register(registers, y, 8),
          scanline_register(registers, y, 12),
          x,
          y,
          3
        )

      tiled_mode? = Nx.logical_or(mode == 0, mode == 1)
      key0 = Nx.select(tiled_mode?, key0, 255)
      key1 = Nx.select(tiled_mode?, key1, 255)
      key2 = Nx.select(mode == 0, regular_key2, Nx.select(mode == 1, affine_key2, 255))
      color2 = Nx.select(mode == 1, affine_color2, regular_color2)
      key3 = Nx.select(mode == 0, key3, 255)
      key0 = window_layer_key(key0, window_control, 0)
      key1 = window_layer_key(key1, window_control, 1)
      key2 = window_layer_key(key2, window_control, 2)
      key3 = window_layer_key(key3, window_control, 3)

      backdrop = Nx.broadcast(palette_color(palette, 0), {pixel_count})
      layers = initial_layers(backdrop)
      layers = insert_layer(layers, key0, color0, 0)
      layers = insert_layer(layers, key1, color1, 1)
      layers = insert_layer(layers, key2, color2, 2)
      layers = insert_layer(layers, key3, color3, 3)

      {dispcnt, x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode}
    end

    defnp render_mode1_tiled_pixels(vram, palette, objects, registers) do
      y = Nx.iota({160, 240}, axis: 0, type: :s32) |> Nx.flatten()
      render_mode1_region(vram, palette, objects, registers, y)
    end

    defnp render_mode0_region(vram, palette, objects, registers, y) do
      {_dispcnt, _x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode} = mode0_region_layers(vram, palette, objects, registers, y)

      composite_tiled_layers(
        registers,
        y,
        window_control,
        layers,
        object_valid?,
        object_priority,
        object_color,
        object_graphics_mode
      )
    end

    defnp render_mode0_no_bg2_region(vram, palette, objects, registers, y) do
      {_dispcnt, _x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode} =
        mode0_no_bg2_region_layers(vram, palette, objects, registers, y)

      composite_tiled_layers(
        registers,
        y,
        window_control,
        layers,
        object_valid?,
        object_priority,
        object_color,
        object_graphics_mode
      )
    end

    defnp mode0_region_layers(vram, palette, objects, registers, y) do
      pixel_count = Nx.axis_size(y, 0)
      x = Nx.iota({pixel_count}, type: :s32) |> Nx.remainder(240)
      dispcnt = scanline_register(registers, y, 0)
      control0 = scanline_background_control(registers, y, 0)
      control1 = scanline_background_control(registers, y, 1)
      control2 = scanline_background_control(registers, y, 2)
      control3 = scanline_background_control(registers, y, 3)

      {object_valid?, object_priority, object_color, object_graphics_mode, object_window?} =
        object_layer(vram, palette, objects, dispcnt, 0, x, y)

      window_control = window_control(registers, dispcnt, x, y, object_window?)
      object_valid? = Nx.logical_and(object_valid?, bit_set?(window_control, 4))

      {key0, color0} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control0,
          scanline_register(registers, y, 5),
          scanline_register(registers, y, 9),
          x,
          y,
          0
        )

      {key1, color1} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control1,
          scanline_register(registers, y, 6),
          scanline_register(registers, y, 10),
          x,
          y,
          1
        )

      {key2, color2} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control2,
          scanline_register(registers, y, 7),
          scanline_register(registers, y, 11),
          x,
          y,
          2
        )

      {key3, color3} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control3,
          scanline_register(registers, y, 8),
          scanline_register(registers, y, 12),
          x,
          y,
          3
        )

      layers = initial_layers(Nx.broadcast(palette_color(palette, 0), {pixel_count}))
      layers = insert_layer(layers, window_layer_key(key0, window_control, 0), color0, 0)
      layers = insert_layer(layers, window_layer_key(key1, window_control, 1), color1, 1)
      layers = insert_layer(layers, window_layer_key(key2, window_control, 2), color2, 2)
      layers = insert_layer(layers, window_layer_key(key3, window_control, 3), color3, 3)

      {dispcnt, x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode}
    end

    defnp mode0_no_bg2_region_layers(vram, palette, objects, registers, y) do
      pixel_count = Nx.axis_size(y, 0)
      x = Nx.iota({pixel_count}, type: :s32) |> Nx.remainder(240)
      dispcnt = scanline_register(registers, y, 0)
      control0 = scanline_background_control(registers, y, 0)
      control1 = scanline_background_control(registers, y, 1)
      control3 = scanline_background_control(registers, y, 3)

      {object_valid?, object_priority, object_color, object_graphics_mode, object_window?} =
        object_layer(vram, palette, objects, dispcnt, 0, x, y)

      window_control = window_control(registers, dispcnt, x, y, object_window?)
      object_valid? = Nx.logical_and(object_valid?, bit_set?(window_control, 4))

      {key0, color0} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control0,
          scanline_register(registers, y, 5),
          scanline_register(registers, y, 9),
          x,
          y,
          0
        )

      {key1, color1} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control1,
          scanline_register(registers, y, 6),
          scanline_register(registers, y, 10),
          x,
          y,
          1
        )

      {key3, color3} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control3,
          scanline_register(registers, y, 8),
          scanline_register(registers, y, 12),
          x,
          y,
          3
        )

      layers = initial_layers(Nx.broadcast(palette_color(palette, 0), {pixel_count}))
      layers = insert_layer(layers, window_layer_key(key0, window_control, 0), color0, 0)
      layers = insert_layer(layers, window_layer_key(key1, window_control, 1), color1, 1)
      layers = insert_layer(layers, window_layer_key(key3, window_control, 3), color3, 3)

      {dispcnt, x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode}
    end

    defnp render_mode1_region(vram, palette, objects, registers, y) do
      {_dispcnt, _x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode} = mode1_region_layers(vram, palette, objects, registers, y)

      composite_tiled_layers(
        registers,
        y,
        window_control,
        layers,
        object_valid?,
        object_priority,
        object_color,
        object_graphics_mode
      )
    end

    defnp mode1_region_layers(vram, palette, objects, registers, y) do
      pixel_count = Nx.axis_size(y, 0)
      x = Nx.iota({pixel_count}, type: :s32) |> Nx.remainder(240)
      dispcnt = scanline_register(registers, y, 0)
      control0 = scanline_background_control(registers, y, 0)
      control1 = scanline_background_control(registers, y, 1)
      control2 = scanline_background_control(registers, y, 2)

      {object_valid?, object_priority, object_color, object_graphics_mode, object_window?} =
        object_layer(vram, palette, objects, dispcnt, 0, x, y)

      window_control = window_control(registers, dispcnt, x, y, object_window?)
      object_valid? = Nx.logical_and(object_valid?, bit_set?(window_control, 4))

      {key0, color0} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control0,
          scanline_register(registers, y, 5),
          scanline_register(registers, y, 9),
          x,
          y,
          0
        )

      {key1, color1} =
        background_layer(
          vram,
          palette,
          dispcnt,
          control1,
          scanline_register(registers, y, 6),
          scanline_register(registers, y, 10),
          x,
          y,
          1
        )

      {key2, color2} =
        affine_background_layer(
          vram,
          palette,
          dispcnt,
          control2,
          scanline_register(registers, y, 13),
          scanline_register(registers, y, 14),
          scanline_register(registers, y, 15),
          scanline_register(registers, y, 16),
          scanline_register(registers, y, 17),
          scanline_register(registers, y, 18),
          x,
          y,
          2
        )

      layers = initial_layers(Nx.broadcast(palette_color(palette, 0), {pixel_count}))
      layers = insert_layer(layers, window_layer_key(key0, window_control, 0), color0, 0)
      layers = insert_layer(layers, window_layer_key(key1, window_control, 1), color1, 1)
      layers = insert_layer(layers, window_layer_key(key2, window_control, 2), color2, 2)

      {dispcnt, x, window_control, layers, object_valid?, object_priority, object_color,
       object_graphics_mode}
    end

    defnp composite_tiled_layers(
            registers,
            y,
            window_control,
            layers,
            object_valid?,
            object_priority,
            object_color,
            object_graphics_mode
          ) do
      object_key = Nx.select(object_valid?, object_priority * 8, 255)

      {_first_key, color, source, _second_key, second_color, second_source} =
        insert_layer(layers, object_key, object_color, 4)

      semi_transparent? = Nx.logical_and(source == 4, object_graphics_mode == 1)

      color =
        color_effect(
          color,
          source,
          second_color,
          second_source,
          scanline_register(registers, y, 33),
          scanline_register(registers, y, 34),
          scanline_register(registers, y, 35),
          semi_transparent?,
          bit_set?(window_control, 5)
        )

      colors_to_rgb(color)
    end

    defn render_mode3_pixels(vram, palette, objects, registers) do
      pairs = Nx.reshape(Nx.slice(vram, [0], [@frame_bytes]), {@pixels, 2})
      low = pairs |> Nx.slice_along_axis(0, 1, axis: 1) |> Nx.squeeze(axes: [1])
      high = pairs |> Nx.slice_along_axis(1, 1, axis: 1) |> Nx.squeeze(axes: [1])
      background = Nx.as_type(low, :s32) + Nx.as_type(high, :s32) * 256
      x = Nx.iota({@pixels}, type: :s32) |> Nx.remainder(240)
      y = Nx.iota({160, 240}, axis: 0, type: :s32) |> Nx.flatten()
      dispcnt = scanline_register(registers, y, 0)

      {object_valid?, object_priority, object_color, object_graphics_mode, object_window?} =
        object_layer(vram, palette, objects, dispcnt, 1, x, y)

      window_control = window_control(registers, dispcnt, x, y, object_window?)

      background_priority =
        registers |> scanline_background_control(y, 2) |> Nx.bitwise_and(0x3)

      background_key =
        Nx.select(
          Nx.logical_and(Nx.bitwise_and(dispcnt, 0x7) == 3, bit_set?(dispcnt, 10)),
          background_priority * 8 + 3,
          255
        )

      background_key = window_layer_key(background_key, window_control, 2)

      backdrop = Nx.broadcast(palette_color(palette, 0), {@pixels})
      layers = initial_layers(backdrop)
      layers = insert_layer(layers, background_key, background, 2)

      object_valid? = Nx.logical_and(object_valid?, bit_set?(window_control, 4))
      object_key = Nx.select(object_valid?, object_priority * 8, 255)

      {_first_key, color, source, _second_key, second_color, second_source} =
        insert_layer(layers, object_key, object_color, 4)

      semi_transparent? = Nx.logical_and(source == 4, object_graphics_mode == 1)

      color =
        color_effect(
          color,
          source,
          second_color,
          second_source,
          scanline_register(registers, y, 33),
          scanline_register(registers, y, 34),
          scanline_register(registers, y, 35),
          semi_transparent?,
          bit_set?(window_control, 5)
        )

      colors_to_rgb(color)
    end

    defn render_pixels(bytes) do
      pairs = Nx.reshape(bytes, {@pixels, 2})

      low = pairs |> Nx.slice_along_axis(0, 1, axis: 1) |> Nx.squeeze(axes: [1])
      high = pairs |> Nx.slice_along_axis(1, 1, axis: 1) |> Nx.squeeze(axes: [1])
      pixels = Nx.as_type(low, :u16) + Nx.as_type(high, :u16) * 256

      colors_to_rgb(pixels)
    end

    defnp colors_to_rgb(color) do
      color = Nx.bitwise_and(color, 0x7FFF)
      offsets = color * 3
      indexes = Nx.stack([offsets, offsets + 1, offsets + 2], axis: 1)
      Nx.take(Nx.from_binary(@color_table, :u8), indexes)
    end

    defnp color_effect(
            first,
            first_source,
            second,
            second_source,
            control,
            alpha,
            brightness,
            semi_transparent?,
            effects_enabled?
          ) do
      target1? = Nx.bitwise_and(Nx.right_shift(control, first_source), 1) != 0
      target2? = Nx.bitwise_and(Nx.right_shift(control, second_source + 8), 1) != 0
      mode = Nx.bitwise_and(Nx.right_shift(control, 6), 0x3)
      eva = clamp_coefficient(Nx.bitwise_and(alpha, 0x1F))
      evb = clamp_coefficient(Nx.bitwise_and(Nx.right_shift(alpha, 8), 0x1F))
      evy = clamp_coefficient(Nx.bitwise_and(brightness, 0x1F))

      alpha? =
        target2?
        |> Nx.logical_and(Nx.logical_or(semi_transparent?, Nx.logical_and(target1?, mode == 1)))
        |> Nx.logical_and(effects_enabled?)

      brighten? =
        alpha?
        |> Nx.logical_not()
        |> Nx.logical_and(effects_enabled?)
        |> Nx.logical_and(target1?)
        |> Nx.logical_and(mode == 2)

      darken? =
        alpha?
        |> Nx.logical_not()
        |> Nx.logical_and(effects_enabled?)
        |> Nx.logical_and(target1?)
        |> Nx.logical_and(mode == 3)

      red =
        effect_component(
          Nx.bitwise_and(first, 0x1F),
          Nx.bitwise_and(second, 0x1F),
          eva,
          evb,
          evy,
          alpha?,
          brighten?,
          darken?
        )

      green =
        effect_component(
          Nx.bitwise_and(Nx.right_shift(first, 5), 0x1F),
          Nx.bitwise_and(Nx.right_shift(second, 5), 0x1F),
          eva,
          evb,
          evy,
          alpha?,
          brighten?,
          darken?
        )

      blue =
        effect_component(
          Nx.bitwise_and(Nx.right_shift(first, 10), 0x1F),
          Nx.bitwise_and(Nx.right_shift(second, 10), 0x1F),
          eva,
          evb,
          evy,
          alpha?,
          brighten?,
          darken?
        )

      red + Nx.left_shift(green, 5) + Nx.left_shift(blue, 10)
    end

    defnp effect_component(
            first,
            second,
            eva,
            evb,
            evy,
            alpha?,
            brighten?,
            darken?
          ) do
      blended = clamp_color(Nx.right_shift(first * eva + second * evb, 4))
      brightened = first + Nx.right_shift((31 - first) * evy, 4)
      darkened = first - Nx.right_shift(first * evy, 4)

      Nx.select(
        alpha?,
        blended,
        Nx.select(brighten?, brightened, Nx.select(darken?, darkened, first))
      )
    end

    defnp(clamp_coefficient(value), do: Nx.select(value > 16, 16, value))
    defnp(clamp_color(value), do: Nx.select(value > 31, 31, value))

    defnp background_layer(vram, palette, dispcnt, control, horizontal, vertical, x, y, layer) do
      size = Nx.right_shift(control, 14)
      width = Nx.select(Nx.bitwise_and(size, 1) == 1, 512, 256)
      height = Nx.select(Nx.bitwise_and(size, 2) == 2, 512, 256)
      background_x = Nx.remainder(x + horizontal, width)
      background_y = Nx.remainder(y + vertical, height)
      tile_x = Nx.quotient(background_x, 8)
      tile_y = Nx.quotient(background_y, 8)
      blocks_wide = Nx.quotient(width, 256)

      screen_block =
        Nx.bitwise_and(Nx.right_shift(control, 8), 0x1F) +
          Nx.quotient(tile_y, 32) * blocks_wide + Nx.quotient(tile_x, 32)

      entry_index = Nx.remainder(tile_y, 32) * 32 + Nx.remainder(tile_x, 32)
      entry_offset = screen_block * 0x800 + entry_index * 2
      entry = little16(vram, entry_offset)
      local_x = Nx.remainder(background_x, 8)
      local_y = Nx.remainder(background_y, 8)
      pixel_x = Nx.select(bit_set?(entry, 10), 7 - local_x, local_x)
      pixel_y = Nx.select(bit_set?(entry, 11), 7 - local_y, local_y)
      tile = Nx.bitwise_and(entry, 0x3FF)
      character_base = Nx.bitwise_and(Nx.right_shift(control, 2), 0x3) * 0x4000

      eight_bit_index =
        vram_byte(vram, character_base + tile * 64 + pixel_y * 8 + pixel_x)

      packed =
        vram_byte(
          vram,
          character_base + tile * 32 + pixel_y * 4 + Nx.quotient(pixel_x, 2)
        )

      four_bit_index =
        Nx.select(
          Nx.remainder(pixel_x, 2) == 0,
          Nx.bitwise_and(packed, 0xF),
          Nx.right_shift(packed, 4)
        )

      eight_bit? = bit_set?(control, 7)
      color_index = Nx.select(eight_bit?, eight_bit_index, four_bit_index)
      palette_bank = Nx.right_shift(entry, 12)
      palette_index = Nx.select(eight_bit?, color_index, palette_bank * 16 + color_index)
      color = palette_color(palette, palette_index)
      priority = Nx.bitwise_and(control, 0x3)

      visible? =
        Nx.logical_and(bit_set?(dispcnt, 8 + layer), color_index != 0)

      key = Nx.select(visible?, priority * 8 + layer + 1, 255)
      {key, color}
    end

    defnp affine_background_layer(
            vram,
            palette,
            dispcnt,
            control,
            raw_pa,
            _raw_pb,
            raw_pc,
            _raw_pd,
            raw_reference_x,
            raw_reference_y,
            x,
            _y,
            layer
          ) do
      pa = signed16(raw_pa)
      pc = signed16(raw_pc)
      reference_x = signed28(raw_reference_x)
      reference_y = signed28(raw_reference_y)
      size = Nx.left_shift(128, Nx.right_shift(control, 14))
      transformed_x = Nx.right_shift(reference_x + pa * x, 8)
      transformed_y = Nx.right_shift(reference_y + pc * x, 8)

      inside? =
        (transformed_x >= 0)
        |> Nx.logical_and(transformed_x < size)
        |> Nx.logical_and(transformed_y >= 0)
        |> Nx.logical_and(transformed_y < size)

      background_x = positive_remainder(transformed_x, size)
      background_y = positive_remainder(transformed_y, size)
      tiles_wide = Nx.quotient(size, 8)
      screen_base = Nx.bitwise_and(Nx.right_shift(control, 8), 0x1F) * 0x800

      tile =
        vram_byte(
          vram,
          screen_base + Nx.quotient(background_y, 8) * tiles_wide +
            Nx.quotient(background_x, 8)
        )

      character_base = Nx.bitwise_and(Nx.right_shift(control, 2), 0x3) * 0x4000

      color_index =
        vram_byte(
          vram,
          character_base + tile * 64 + Nx.remainder(background_y, 8) * 8 +
            Nx.remainder(background_x, 8)
        )

      visible? =
        bit_set?(dispcnt, 8 + layer)
        |> Nx.logical_and(Nx.logical_or(bit_set?(control, 13), inside?))
        |> Nx.logical_and(color_index != 0)

      priority = Nx.bitwise_and(control, 0x3)
      key = Nx.select(visible?, priority * 8 + layer + 1, 255)
      {key, palette_color(palette, color_index)}
    end

    defnp initial_layers(backdrop) do
      pixel_count = Nx.axis_size(backdrop, 0)
      first_key = Nx.broadcast(Nx.tensor(38, type: :s32), {pixel_count})
      first_source = Nx.broadcast(Nx.tensor(5, type: :s32), {pixel_count})
      second_key = Nx.broadcast(Nx.tensor(255, type: :s32), {pixel_count})
      second_source = Nx.broadcast(Nx.tensor(6, type: :s32), {pixel_count})
      {first_key, backdrop, first_source, second_key, backdrop, second_source}
    end

    defnp insert_layer(
            {first_key, first_color, first_source, second_key, second_color, second_source},
            key,
            color,
            source
          ) do
      first? = key < first_key
      second? = Nx.logical_and(Nx.logical_not(first?), key < second_key)

      {
        Nx.select(first?, key, first_key),
        Nx.select(first?, color, first_color),
        Nx.select(first?, source, first_source),
        Nx.select(first?, first_key, Nx.select(second?, key, second_key)),
        Nx.select(first?, first_color, Nx.select(second?, color, second_color)),
        Nx.select(first?, first_source, Nx.select(second?, source, second_source))
      }
    end

    defnp scanline_background_control(registers, y, layer) do
      scanline_register(registers, y, 1 + layer)
    end

    defnp window_control(registers, dispcnt, x, y, object_window?) do
      horizontal0 = scanline_register(registers, y, 25)
      horizontal1 = scanline_register(registers, y, 26)
      vertical0 = scanline_register(registers, y, 27)
      vertical1 = scanline_register(registers, y, 28)
      inside = scanline_register(registers, y, 29)
      outside = scanline_register(registers, y, 30)

      window0? =
        bit_set?(dispcnt, 13)
        |> Nx.logical_and(inside_window_axis?(x, horizontal0, 240))
        |> Nx.logical_and(inside_window_axis?(y, vertical0, 160))

      window1? =
        bit_set?(dispcnt, 14)
        |> Nx.logical_and(inside_window_axis?(x, horizontal1, 240))
        |> Nx.logical_and(inside_window_axis?(y, vertical1, 160))

      windows_enabled? = Nx.bitwise_and(dispcnt, 0xE000) != 0
      window0_control = Nx.bitwise_and(inside, 0x3F)
      window1_control = inside |> Nx.right_shift(8) |> Nx.bitwise_and(0x3F)
      outside_control = Nx.bitwise_and(outside, 0x3F)
      object_window_control = outside |> Nx.right_shift(8) |> Nx.bitwise_and(0x3F)
      object_window? = Nx.logical_and(bit_set?(dispcnt, 15), object_window?)

      Nx.select(
        windows_enabled?,
        Nx.select(
          window0?,
          window0_control,
          Nx.select(
            window1?,
            window1_control,
            Nx.select(object_window?, object_window_control, outside_control)
          )
        ),
        0x3F
      )
    end

    defnp inside_window_axis?(coordinate, limits, extent) do
      first = limits |> Nx.right_shift(8) |> Nx.bitwise_and(0xFF)
      last = Nx.bitwise_and(limits, 0xFF)

      regular? =
        (first < last)
        |> Nx.logical_and(coordinate >= first)
        |> Nx.logical_and(coordinate < last)

      wrapped? =
        (first > last)
        |> Nx.logical_and(Nx.logical_or(coordinate >= first, coordinate < last))

      Nx.logical_or(last > extent, Nx.logical_or(regular?, wrapped?))
    end

    defnp window_layer_key(key, window_control, layer) do
      Nx.select(bit_set?(window_control, layer), key, 255)
    end

    defnp scanline_register(registers, y, offset) do
      Nx.take(registers, @scanline_register_start + y * @scanline_register_stride + offset)
    end

    defnp object_layer(vram, palette, objects, dispcnt, bitmap_mode, x, y) do
      pixel_count = Nx.axis_size(x, 0)
      line_count = div(pixel_count, 240)
      object_count = Nx.axis_size(objects, 1)
      x = Nx.reshape(x, {line_count, 240})
      y = Nx.reshape(y, {line_count, 240})

      line_y =
        y
        |> Nx.slice_along_axis(0, 1, axis: 1)
        |> Nx.squeeze(axes: [1])

      objects = Nx.take(objects, line_y)

      pixel_dispcnt =
        dispcnt
        |> Nx.reshape({line_count, 240})
        |> Nx.new_axis(1)
        |> Nx.broadcast({line_count, object_count, 240})

      attr0 = objects[[.., .., 0]] |> Nx.new_axis(2)
      attr1 = objects[[.., .., 1]] |> Nx.new_axis(2)
      attr2 = objects[[.., .., 2]] |> Nx.new_axis(2)
      object_index = objects[[.., .., 3]] |> Nx.new_axis(2)
      pa = objects[[.., .., 4]] |> Nx.new_axis(2) |> signed16()
      pb = objects[[.., .., 5]] |> Nx.new_axis(2) |> signed16()
      pc = objects[[.., .., 6]] |> Nx.new_axis(2) |> signed16()
      pd = objects[[.., .., 7]] |> Nx.new_axis(2) |> signed16()
      shape = Nx.bitwise_and(Nx.right_shift(attr0, 14), 0x3)
      size = Nx.bitwise_and(Nx.right_shift(attr1, 14), 0x3)
      {width, height} = object_dimensions(shape, size)
      object_mode = Nx.bitwise_and(Nx.right_shift(attr0, 8), 0x3)
      affine? = object_mode != 0
      double_size? = object_mode == 3
      display_width = Nx.select(double_size?, width * 2, width)
      display_height = Nx.select(double_size?, height * 2, height)
      raw_x = Nx.bitwise_and(attr1, 0x1FF)
      raw_y = Nx.bitwise_and(attr0, 0xFF)
      base_x = Nx.select(raw_x >= 256, raw_x - 512, raw_x)
      base_y = Nx.select(raw_y + display_height > 256, raw_y - 256, raw_y)
      object_x = base_x
      object_y = base_y
      x = Nx.new_axis(x, 1)
      y = Nx.new_axis(y, 1)
      local_x = x - object_x
      local_y = y - object_y

      object_pixel_shape = {line_count, object_count, 240}
      horizontal_flip? = Nx.broadcast(bit_set?(attr1, 12), object_pixel_shape)
      vertical_flip? = Nx.broadcast(bit_set?(attr1, 13), object_pixel_shape)
      pixel_affine? = Nx.broadcast(affine?, object_pixel_shape)
      regular_x = Nx.select(horizontal_flip?, width - local_x - 1, local_x)
      regular_y = Nx.select(vertical_flip?, height - local_y - 1, local_y)
      centered_x = local_x - Nx.quotient(display_width, 2)
      centered_y = local_y - Nx.quotient(display_height, 2)

      affine_x =
        Nx.right_shift(pa * centered_x + pb * centered_y, 8) + Nx.quotient(width, 2)

      affine_y =
        Nx.right_shift(pc * centered_x + pd * centered_y, 8) + Nx.quotient(height, 2)

      pixel_x = Nx.select(pixel_affine?, affine_x, regular_x)
      pixel_y = Nx.select(pixel_affine?, affine_y, regular_y)

      source_inside? =
        (pixel_x >= 0)
        |> Nx.logical_and(pixel_x < width)
        |> Nx.logical_and(pixel_y >= 0)
        |> Nx.logical_and(pixel_y < height)

      safe_pixel_x = Nx.select(pixel_x < 0, 0, Nx.select(pixel_x >= width, width - 1, pixel_x))
      safe_pixel_y = Nx.select(pixel_y < 0, 0, Nx.select(pixel_y >= height, height - 1, pixel_y))
      eight_bit? = bit_set?(attr0, 13)
      pixel_eight_bit? = Nx.broadcast(eight_bit?, object_pixel_shape)
      units_per_tile = Nx.select(eight_bit?, 2, 1)
      one_dimensional? = bit_set?(pixel_dispcnt, 6)

      one_dimensional_units =
        Nx.broadcast(Nx.quotient(width, 8) * units_per_tile, object_pixel_shape)

      row_units =
        Nx.select(one_dimensional?, one_dimensional_units, 32)

      object_tile = Nx.bitwise_and(attr2, 0x3FF)
      base_tile = Nx.select(eight_bit?, Nx.bitwise_and(object_tile, 0x3FE), object_tile)

      tile =
        base_tile + Nx.quotient(safe_pixel_y, 8) * row_units +
          Nx.quotient(safe_pixel_x, 8) * units_per_tile

      in_tile_x = Nx.remainder(safe_pixel_x, 8)
      in_tile_y = Nx.remainder(safe_pixel_y, 8)

      eight_bit_index =
        vram_byte(vram, 0x10_000 + tile * 32 + in_tile_y * 8 + in_tile_x)

      packed =
        vram_byte(
          vram,
          0x10_000 + tile * 32 + in_tile_y * 4 + Nx.quotient(in_tile_x, 2)
        )

      four_bit_index =
        Nx.select(
          Nx.remainder(in_tile_x, 2) == 0,
          Nx.bitwise_and(packed, 0xF),
          Nx.right_shift(packed, 4)
        )

      color_index = Nx.select(pixel_eight_bit?, eight_bit_index, four_bit_index)
      palette_bank = Nx.right_shift(attr2, 12)

      palette_index =
        Nx.select(pixel_eight_bit?, color_index, palette_bank * 16 + color_index)

      colors = palette_color(palette, 256 + palette_index)
      graphics_mode = Nx.bitwise_and(Nx.right_shift(attr0, 10), 0x3)

      visible? =
        bit_set?(pixel_dispcnt, 12)
        |> Nx.logical_and(object_mode != 2)
        |> Nx.logical_and(shape != 3)
        |> Nx.logical_and(local_x >= 0)
        |> Nx.logical_and(local_x < display_width)
        |> Nx.logical_and(local_y >= 0)
        |> Nx.logical_and(local_y < display_height)
        |> Nx.logical_and(source_inside?)
        |> Nx.logical_and(color_index != 0)
        |> Nx.logical_and(Nx.logical_or(bitmap_mode == 0, object_tile >= 512))

      valid? = Nx.logical_and(visible?, graphics_mode < 2)

      object_window? =
        visible?
        |> Nx.logical_and(bit_set?(pixel_dispcnt, 15))
        |> Nx.logical_and(graphics_mode == 2)

      object_window? = object_window? |> Nx.any(axes: [1]) |> Nx.flatten()

      object_priorities = attr2 |> Nx.right_shift(10) |> Nx.bitwise_and(0x3)
      keys = Nx.select(valid?, object_priorities * 128 + object_index, 1024)
      winner = Nx.argmin(keys, axis: 1)
      line_index = Nx.iota({line_count, 240}, axis: 0, type: :s32)
      pixel_index = Nx.iota({line_count, 240}, axis: 1, type: :s32)
      winner_pixel = (line_index * object_count + winner) * 240 + pixel_index
      winner_key = Nx.take(Nx.flatten(keys), Nx.flatten(winner_pixel))
      winner_color = Nx.take(Nx.flatten(colors), Nx.flatten(winner_pixel))
      winner_object = Nx.flatten(line_index * object_count + winner)
      priorities = Nx.flatten(object_priorities)
      winner_priority = Nx.take(priorities, winner_object)
      graphics_modes = attr0 |> Nx.right_shift(10) |> Nx.bitwise_and(0x3) |> Nx.flatten()
      winner_graphics_mode = Nx.take(graphics_modes, winner_object)

      {winner_key != 1024, winner_priority, winner_color, winner_graphics_mode, object_window?}
    end

    defnp object_dimensions(shape, size) do
      square = Nx.left_shift(8, size)

      horizontal_width =
        Nx.select(size == 0, 16, Nx.select(size == 1, 32, Nx.select(size == 2, 32, 64)))

      horizontal_height =
        Nx.select(size == 0, 8, Nx.select(size == 1, 8, Nx.select(size == 2, 16, 32)))

      vertical_width =
        Nx.select(size == 0, 8, Nx.select(size == 1, 8, Nx.select(size == 2, 16, 32)))

      vertical_height =
        Nx.select(size == 0, 16, Nx.select(size == 1, 32, Nx.select(size == 2, 32, 64)))

      width =
        Nx.select(shape == 0, square, Nx.select(shape == 1, horizontal_width, vertical_width))

      height =
        Nx.select(shape == 0, square, Nx.select(shape == 1, horizontal_height, vertical_height))

      {width, height}
    end

    defnp(palette_color(palette, index), do: little16(palette, index * 2))

    defnp little16(memory, offset) do
      low = Nx.take(memory, offset) |> Nx.as_type(:s32)
      high = Nx.take(memory, offset + 1) |> Nx.as_type(:s32)
      low + high * 256
    end

    defnp vram_byte(vram, offset) do
      offset = Nx.remainder(offset, 0x20_000)
      offset = Nx.select(offset >= 0x18_000, offset - 0x8_000, offset)
      Nx.take(vram, offset) |> Nx.as_type(:s32)
    end

    defnp(signed16(value), do: Nx.select(value >= 0x8000, value - 0x1_0000, value))
    defnp(signed28(value), do: Nx.select(value >= 0x0800_0000, value - 0x1000_0000, value))

    defnp positive_remainder(value, divisor) do
      Nx.remainder(Nx.remainder(value, divisor) + divisor, divisor)
    end

    defnp(bit_set?(value, bit),
      do: Nx.bitwise_and(value, Nx.left_shift(1, bit)) != 0
    )

    defp input(binary, size) do
      binary
      |> binary_part(0, size)
      |> Nx.from_binary(:u8)
      |> Nx.backend_copy(Beamicom.GBA.Nx.backend())
    end

    defp cached_input(name, binary, size) do
      backend = Beamicom.GBA.Nx.backend()
      key = {__MODULE__, :input, name, backend}

      case Process.get(key) do
        {^binary, input} ->
          input

        _missing_or_changed ->
          input = input(binary, size)
          Process.put(key, {binary, input})
          input
      end
    end

    defp register_input(registers) do
      affine =
        Map.get(
          registers,
          :bg_affine,
          {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}}
        )

      effects = Map.get(registers, :display_effects, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})

      snapshot =
        {registers.dispcnt, registers.bgcnt, registers.bghofs, registers.bgvofs, affine, effects,
         Map.get(registers, :scanline_dispcnt), Map.get(registers, :scanline_bgcnt),
         Map.get(registers, :scanline_bghofs), Map.get(registers, :scanline_bgvofs),
         Map.get(registers, :scanline_bg_affine), Map.get(registers, :scanline_display_effects)}

      backend = Beamicom.GBA.Nx.backend()
      key = {__MODULE__, :register_input, backend}

      case Process.get(key) do
        {^snapshot, input} ->
          input

        _missing_or_changed ->
          input = build_register_input(registers, affine, effects)
          Process.put(key, {snapshot, input})
          input
      end
    end

    defp build_register_input(registers, affine, effects) do
      scanlines =
        for y <- 0..159, into: <<>> do
          line_affine =
            scanline_host_value(
              registers,
              :scanline_bg_affine,
              y,
              effective_host_affine(affine, y)
            )

          line_effects =
            scanline_host_value(registers, :scanline_display_effects, y, effects)

          register_binary(
            scanline_host_value(registers, :scanline_dispcnt, y, registers.dispcnt),
            scanline_host_value(registers, :scanline_bgcnt, y, registers.bgcnt),
            scanline_host_value(registers, :scanline_bghofs, y, registers.bghofs),
            scanline_host_value(registers, :scanline_bgvofs, y, registers.bgvofs),
            line_affine,
            line_effects
          )
        end

      registers.dispcnt
      |> register_binary(
        registers.bgcnt,
        registers.bghofs,
        registers.bgvofs,
        affine,
        effects
      )
      |> Kernel.<>(scanlines)
      |> s32_binary_input()
    end

    defp scanline_host_value(registers, field, y, fallback) do
      case Map.get(registers, field) do
        scanlines when is_tuple(scanlines) and tuple_size(scanlines) == 160 ->
          elem(scanlines, y)

        _missing ->
          fallback
      end
    end

    defp effective_host_affine({background2, background3}, y) do
      {effective_host_affine_background(background2, y),
       effective_host_affine_background(background3, y)}
    end

    defp effective_host_affine_background({pa, pb, pc, pd, reference_x, reference_y}, y) do
      {pa, pb, pc, pd, reference_x + host_signed16(pb) * y &&& 0x0FFF_FFFF,
       reference_y + host_signed16(pd) * y &&& 0x0FFF_FFFF}
    end

    defp host_signed16(value) when value >= 0x8000, do: value - 0x1_0000
    defp host_signed16(value), do: value

    defp object_input(oam, bitmap_mode?) do
      backend = Beamicom.GBA.Nx.backend()
      key = {__MODULE__, :object_input, bitmap_mode?, backend}

      case Process.get(key) do
        {^oam, input} ->
          input

        _missing_or_changed ->
          input = build_object_input(oam, bitmap_mode?)
          Process.put(key, {oam, input})
          input
      end
    end

    defp build_object_input(oam, bitmap_mode?) do
      objects =
        for index <- 0..127,
            object = host_object(oam, index, bitmap_mode?),
            not is_nil(object),
            do: packed_object(object)

      scanlines =
        for line <- 0..159 do
          for {object, first_line, last_line} <- objects,
              line >= first_line and line <= last_line,
              do: object
        end

      maximum = scanlines |> Enum.map(&length/1) |> Enum.max()
      bucket = Enum.find(@object_buckets, 128, &(maximum <= &1))

      scanlines
      |> Enum.map(fn line_objects ->
        [line_objects, :binary.copy(@hidden_object, bucket - length(line_objects))]
      end)
      |> IO.iodata_to_binary()
      |> s32_binary_input({160, bucket, 8})
    end

    defp packed_object({values, first_line, last_line}),
      do: {pack_s32(values), first_line, last_line}

    defp s32_input(values, shape) do
      values |> pack_s32() |> s32_binary_input(shape)
    end

    defp pack_s32(values), do: for(value <- values, into: <<>>, do: <<value::little-signed-32>>)

    defp register_binary(
           dispcnt,
           {bgcnt0, bgcnt1, bgcnt2, bgcnt3},
           {bghofs0, bghofs1, bghofs2, bghofs3},
           {bgvofs0, bgvofs1, bgvofs2, bgvofs3},
           {{pa2, pb2, pc2, pd2, reference_x2, reference_y2},
            {pa3, pb3, pc3, pd3, reference_x3, reference_y3}},
           {window_horizontal0, window_horizontal1, window_vertical0, window_vertical1,
            window_inside, window_outside, mosaic, blend_control, blend_alpha, blend_brightness,
            green_swap}
         ) do
      <<dispcnt::little-signed-32, bgcnt0::little-signed-32, bgcnt1::little-signed-32,
        bgcnt2::little-signed-32, bgcnt3::little-signed-32, bghofs0::little-signed-32,
        bghofs1::little-signed-32, bghofs2::little-signed-32, bghofs3::little-signed-32,
        bgvofs0::little-signed-32, bgvofs1::little-signed-32, bgvofs2::little-signed-32,
        bgvofs3::little-signed-32, pa2::little-signed-32, pb2::little-signed-32,
        pc2::little-signed-32, pd2::little-signed-32, reference_x2::little-signed-32,
        reference_y2::little-signed-32, pa3::little-signed-32, pb3::little-signed-32,
        pc3::little-signed-32, pd3::little-signed-32, reference_x3::little-signed-32,
        reference_y3::little-signed-32, window_horizontal0::little-signed-32,
        window_horizontal1::little-signed-32, window_vertical0::little-signed-32,
        window_vertical1::little-signed-32, window_inside::little-signed-32,
        window_outside::little-signed-32, mosaic::little-signed-32,
        blend_control::little-signed-32, blend_alpha::little-signed-32,
        blend_brightness::little-signed-32, green_swap::little-signed-32>>
    end

    defp s32_binary_input(binary, shape \\ nil) do
      tensor = Nx.from_binary(binary, :s32)
      tensor = if shape, do: Nx.reshape(tensor, shape), else: tensor
      Nx.backend_copy(tensor, Beamicom.GBA.Nx.backend())
    end

    defp split_y_inputs(split) when split in 1..159 do
      key = {__MODULE__, :split_y_inputs, split, Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          inputs =
            {scanline_y_input(0, split - 1), scanline_y_input(split, split),
             scanline_y_input(split + 1, 159)}

          :persistent_term.put(key, inputs)
          inputs

        inputs ->
          inputs
      end
    end

    defp scanline_y_input(first, last) do
      binary =
        for y <- first..last, into: <<>> do
          :binary.copy(<<y::little-signed-32>>, 240)
        end

      binary
      |> Nx.from_binary(:s32)
      |> Nx.backend_copy(Beamicom.GBA.Nx.backend())
    end

    defp host_object(oam, index, bitmap_mode?) do
      offset = index * 8
      attr0 = host_little16(oam, offset)
      attr1 = host_little16(oam, offset + 2)
      attr2 = host_little16(oam, offset + 4)
      object_mode = attr0 >>> 8 &&& 0x3
      graphics_mode = attr0 >>> 10 &&& 0x3
      shape = attr0 >>> 14
      size = attr1 >>> 14
      {width, height} = host_object_dimensions(shape, size)
      tile = attr2 &&& 0x3FF
      raw_x = attr1 &&& 0x1FF
      raw_y = attr0 &&& 0xFF
      base_x = if raw_x >= 256, do: raw_x - 512, else: raw_x
      double_size? = object_mode == 3
      display_width = if double_size?, do: width * 2, else: width
      display_height = if double_size?, do: height * 2, else: height
      base_y = if raw_y + display_height > 256, do: raw_y - 256, else: raw_y
      x = base_x
      y = base_y

      if object_mode != 2 and graphics_mode < 3 and width > 0 and x < 240 and
           x + display_width > 0 and y < 160 and y + display_height > 0 and
           (not bitmap_mode? or tile >= 512) do
        matrix_base = (attr1 >>> 9 &&& 0x1F) * 32

        {
          [
            attr0,
            attr1,
            attr2,
            index,
            host_little16(oam, matrix_base + 6),
            host_little16(oam, matrix_base + 14),
            host_little16(oam, matrix_base + 22),
            host_little16(oam, matrix_base + 30)
          ],
          max(y, 0),
          min(y + display_height - 1, 159)
        }
      end
    end

    defp host_little16(binary, offset),
      do: :binary.at(binary, offset) ||| :binary.at(binary, offset + 1) <<< 8

    defp host_object_dimensions(0, 0), do: {8, 8}
    defp host_object_dimensions(0, 1), do: {16, 16}
    defp host_object_dimensions(0, 2), do: {32, 32}
    defp host_object_dimensions(0, 3), do: {64, 64}
    defp host_object_dimensions(1, 0), do: {16, 8}
    defp host_object_dimensions(1, 1), do: {32, 8}
    defp host_object_dimensions(1, 2), do: {32, 16}
    defp host_object_dimensions(1, 3), do: {64, 32}
    defp host_object_dimensions(2, 0), do: {8, 16}
    defp host_object_dimensions(2, 1), do: {8, 32}
    defp host_object_dimensions(2, 2), do: {16, 32}
    defp host_object_dimensions(2, 3), do: {32, 64}
    defp host_object_dimensions(_shape, _size), do: {0, 0}

    defp compiled_mode0(args) do
      key =
        {__MODULE__, :render_mode0, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_mode0_pixels/4, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_pure_mode0(args) do
      key =
        {__MODULE__, :render_pure_mode0, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_pure_mode0_pixels/4, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_pure_mode0_no_bg2(args) do
      key =
        {__MODULE__, :render_pure_mode0_no_bg2, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled =
            Beamicom.GBA.Nx.compile(&__MODULE__.render_pure_mode0_no_bg2_pixels/4, args)

          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_mode1(args) do
      key =
        {__MODULE__, :render_mode1, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_mode1_pixels/4, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_mode01(args) do
      key =
        {__MODULE__, :render_mode01, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_mode01_pixels/7, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp tiled_layout(registers) do
      case Map.get(registers, :scanline_dispcnt) do
        scanlines when is_tuple(scanlines) and tuple_size(scanlines) == 160 ->
          scanlines = Tuple.to_list(scanlines)

          if Enum.all?(scanlines, &(rem(&1, 8) == 0 and not bit_set_host?(&1, 10))) do
            :mode0_no_bg2
          else
            scanlines
            |> Enum.map(&rem(&1, 8))
            |> Enum.chunk_by(& &1)
            |> case do
              [[0 | _]] ->
                :mode0

              [[1 | _]] ->
                :mode1

              [[0 | _] = mode0, [1 | _]] when length(mode0) in [74, 75] ->
                {:mode0_mode1_boundary, @common_mode_split}

              _other ->
                :generic
            end
          end

        _missing ->
          case rem(registers.dispcnt, 8) do
            0 -> :mode0
            1 -> :mode1
            _other -> :generic
          end
      end
    end

    defp bit_set_host?(value, bit), do: (value &&& 1 <<< bit) != 0

    defp compiled_mode3(args) do
      key =
        {__MODULE__, :render_mode3, Enum.map(args, &Nx.shape/1),
         Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_mode3_pixels/4, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_raw_mode3(args) do
      key = {__MODULE__, :render_raw_mode3, Beamicom.GBA.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.GBA.Nx.compile(&__MODULE__.render_pixels/1, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end
