if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.SNES.Nx.PPURenderer do
    @moduledoc "Frame-wide Nx renderer for supported 256x224 Mode 1 and Mode 7 paths."

    import Nx.Defn

    @width 256
    @height 224
    @control_columns 40

    @doc "Compiles every supported control-shape variant before realtime playback starts."
    def warmup do
      common = [
        Nx.template({0x10000}, :u8),
        Nx.template({256}, :u16),
        Nx.template({@height, @width, 2}, :u8)
      ]

      for {variant, rows} <- [
            mode1_constant: 1,
            mode1: @height,
            mode1_windowed_constant: 1,
            mode1_windowed: @height,
            mode7_constant: 1,
            mode7: @height
          ] do
        args = [Nx.template({rows, @control_columns}, :s32) | common]
        compiled(args, variant)
      end

      :ok
    end

    def supported?(ppu) do
      states = states(ppu)

      ppu.overscan? == false and length(states) in [1, @height] and
        Enum.uniq_by(states, &elem(&1, 20)) |> length() == 1 and
        supported_mode?(states)
    end

    def render(ppu, object_layer) do
      states = states(ppu)

      control_rows =
        Enum.map(states, fn state ->
          bg_sc = elem(state, 5)
          name = elem(state, 6)
          hofs = elem(state, 7)
          vofs = elem(state, 8)

          [
            elem(state, 1),
            if(elem(state, 3), do: 1, else: 0),
            elem(bg_sc, 0),
            elem(bg_sc, 1),
            elem(bg_sc, 2),
            elem(name, 0),
            elem(name, 1),
            elem(name, 2),
            elem(hofs, 0),
            elem(hofs, 1),
            elem(hofs, 2),
            elem(vofs, 0),
            elem(vofs, 1),
            elem(vofs, 2),
            elem(state, 13),
            elem(state, 14),
            elem(state, 17),
            elem(state, 18),
            elem(state, 19),
            elem(state, 15),
            elem(state, 16),
            elem(elem(state, 10), 0),
            elem(elem(state, 10), 1),
            elem(elem(state, 10), 2),
            elem(elem(state, 11), 0),
            elem(elem(state, 11), 1),
            elem(elem(state, 11), 2),
            elem(elem(state, 11), 3),
            elem(elem(state, 12), 0),
            elem(elem(state, 12), 1),
            elem(state, 22),
            elem(state, 23),
            elem(state, 24),
            elem(state, 25),
            elem(state, 26),
            elem(state, 27),
            elem(state, 28),
            elem(state, 29),
            elem(state, 30),
            if(elem(state, 31), do: 1, else: 0)
          ]
        end)

      controls = controls_tensor(control_rows)

      palette = states |> hd() |> elem(21) |> :array.to_list()

      args = [
        controls,
        vram_tensor(ppu),
        Nx.tensor(palette, type: :u16),
        object_layer |> Nx.from_binary(:u8) |> Nx.reshape({@height, @width, 2})
      ]

      mode = states |> hd() |> elem(2)

      windowed? =
        Enum.any?(states, fn state ->
          elem(state, 15) != 0 or elem(state, 16) != 0 or
            Bitwise.band(elem(state, 17), 0xF0) != 0
        end)

      constant? = length(states) == 1

      variant =
        case {mode, windowed?, constant?} do
          {7, _windowed?, true} -> :mode7_constant
          {7, _windowed?, false} -> :mode7
          {1, true, true} -> :mode1_windowed_constant
          {1, true, false} -> :mode1_windowed
          {1, false, true} -> :mode1_constant
          {1, false, false} -> :mode1
        end

      compiled(args, variant) |> apply(args) |> Nx.to_binary()
    end

    defp supported_mode?(states) do
      mode = states |> hd() |> elem(2)

      case mode do
        1 ->
          Enum.all?(states, &(elem(&1, 2) == 1 and elem(&1, 4) == 0))

        7 ->
          Enum.all?(states, fn state ->
            elem(state, 2) == 7 and elem(state, 10) == {0, 0, 0} and
              Bitwise.band(elem(state, 17), 0xF0) == 0
          end)

        _other ->
          false
      end
    end

    defn render_mode1(controls, vram, palettes, objects) do
      {c0, p0, o0} = background(vram, controls, 0, 4)
      {c1, p1, o1} = background(vram, controls, 1, 4)
      {c2, p2, o2} = background(vram, controls, 2, 2)
      bg3_high = full_column(controls, 1) != 0

      r0 = Nx.select(p0 != 0, Nx.select(bg3_high, 8, 10), Nx.select(bg3_high, 5, 7))
      r1 = Nx.select(p1 != 0, Nx.select(bg3_high, 7, 9), Nx.select(bg3_high, 4, 6))
      r2 = Nx.select(p2 != 0, Nx.select(bg3_high, 10, 3), 1)

      main = full_column(controls, 14)
      sub = full_column(controls, 15)
      object_index = objects[[.., .., 0]] |> Nx.as_type(:s32)
      object_priority = objects[[.., .., 1]] |> Nx.as_type(:s32)

      {main_index, main_layer} =
        compose(
          c0,
          c1,
          c2,
          r0,
          r1,
          r2,
          o0,
          o1,
          o2,
          object_index,
          object_priority,
          main,
          full_column(controls, 19),
          controls,
          bg3_high
        )

      {sub_index, sub_layer} =
        compose(
          c0,
          c1,
          c2,
          r0,
          r1,
          r2,
          o0,
          o1,
          o2,
          object_index,
          object_priority,
          sub,
          full_column(controls, 20),
          controls,
          bg3_high
        )

      first =
        Nx.take(palettes, Nx.flatten(main_index))
        |> Nx.reshape({@height, @width})

      sub_color =
        Nx.take(palettes, Nx.flatten(sub_index))
        |> Nx.reshape({@height, @width})

      select = full_column(controls, 16)
      fixed = full_column(controls, 18)
      use_sub = band(select, 2) != 0
      fixed_fallback = use_sub and sub_layer == 5
      second = Nx.select(use_sub and sub_layer != 5, sub_color, fixed)
      math = full_column(controls, 17)
      enabled = band(shr(math, main_layer), 1) != 0
      enabled = Nx.select(main_layer == 5, band(math, 0x20) != 0, enabled)
      enabled = Nx.select(main_layer == 4, enabled and main_index >= 192, enabled)
      color_window = window_mask(controls, 5)
      first = Nx.select(window_mode_applies(band(shr(select, 6), 3), color_window), 0, first)
      enabled = enabled and not window_mode_applies(band(shr(select, 4), 3), color_window)
      mixed = blend(first, second, Nx.select(fixed_fallback, band(math, 0xBF), math))
      color = Nx.select(enabled, mixed, first)
      brightness = column(controls, 0)

      Nx.stack(
        [
          expand(band(color, 0x1F), brightness),
          expand(band(shr(color, 5), 0x1F), brightness),
          expand(band(shr(color, 10), 0x1F), brightness)
        ],
        axis: 2
      )
      |> Nx.as_type(:u8)
    end

    defn render_mode1_unwindowed(controls, vram, palettes, objects) do
      {c0, p0, o0} = background(vram, controls, 0, 4)
      {c1, p1, o1} = background(vram, controls, 1, 4)
      {c2, p2, o2} = background(vram, controls, 2, 2)
      bg3_high = full_column(controls, 1) != 0

      r0 = Nx.select(p0 != 0, Nx.select(bg3_high, 8, 10), Nx.select(bg3_high, 5, 7))
      r1 = Nx.select(p1 != 0, Nx.select(bg3_high, 7, 9), Nx.select(bg3_high, 4, 6))
      r2 = Nx.select(p2 != 0, Nx.select(bg3_high, 10, 3), 1)
      main = full_column(controls, 14)
      sub = full_column(controls, 15)
      object_index = objects[[.., .., 0]] |> Nx.as_type(:s32)
      object_priority = objects[[.., .., 1]] |> Nx.as_type(:s32)

      {main_index, main_layer} =
        compose_unwindowed(
          c0,
          c1,
          c2,
          r0,
          r1,
          r2,
          o0,
          o1,
          o2,
          object_index,
          object_priority,
          main,
          bg3_high
        )

      {sub_index, sub_layer} =
        compose_unwindowed(
          c0,
          c1,
          c2,
          r0,
          r1,
          r2,
          o0,
          o1,
          o2,
          object_index,
          object_priority,
          sub,
          bg3_high
        )

      first =
        Nx.take(palettes, Nx.flatten(main_index))
        |> Nx.reshape({@height, @width})

      sub_color =
        Nx.take(palettes, Nx.flatten(sub_index))
        |> Nx.reshape({@height, @width})

      select = full_column(controls, 16)
      use_sub = band(select, 2) != 0
      fixed_fallback = use_sub and sub_layer == 5

      second =
        Nx.select(use_sub and sub_layer != 5, sub_color, full_column(controls, 18))

      math = full_column(controls, 17)
      enabled = band(shr(math, main_layer), 1) != 0
      enabled = Nx.select(main_layer == 5, band(math, 0x20) != 0, enabled)
      enabled = Nx.select(main_layer == 4, enabled and main_index >= 192, enabled)
      math = Nx.select(fixed_fallback, band(math, 0xBF), math)
      color = Nx.select(enabled, blend(first, second, math), first)
      brightness = column(controls, 0)

      Nx.stack(
        [
          expand(band(color, 0x1F), brightness),
          expand(band(shr(color, 5), 0x1F), brightness),
          expand(band(shr(color, 10), 0x1F), brightness)
        ],
        axis: 2
      )
      |> Nx.as_type(:u8)
    end

    defn render_mode7(controls, vram, palettes, objects) do
      pixel = mode7_background(vram, controls)
      object_index = objects[[.., .., 0]] |> Nx.as_type(:s32)
      object_priority = objects[[.., .., 1]] |> Nx.as_type(:s32)

      {main_index, main_layer} =
        compose_mode7(
          pixel,
          object_index,
          object_priority,
          full_column(controls, 14),
          full_column(controls, 39)
        )

      {sub_index, sub_layer} =
        compose_mode7(
          pixel,
          object_index,
          object_priority,
          full_column(controls, 15),
          full_column(controls, 39)
        )

      select = full_column(controls, 16)
      palette_main = Nx.take(palettes, Nx.flatten(main_index)) |> Nx.reshape({@height, @width})
      palette_sub = Nx.take(palettes, Nx.flatten(sub_index)) |> Nx.reshape({@height, @width})
      direct_main = mode7_direct_color(main_index)
      direct_sub = mode7_direct_color(sub_index)
      first = Nx.select(band(select, 1) != 0 and main_layer == 0, direct_main, palette_main)
      sub_color = Nx.select(band(select, 1) != 0 and sub_layer == 0, direct_sub, palette_sub)
      use_sub = band(select, 2) != 0
      fixed_fallback = use_sub and sub_layer == 5

      second =
        Nx.select(use_sub and sub_layer != 5, sub_color, full_column(controls, 18))

      math = full_column(controls, 17)
      enabled = band(shr(math, main_layer), 1) != 0
      enabled = Nx.select(main_layer == 5, band(math, 0x20) != 0, enabled)
      enabled = Nx.select(main_layer == 4, enabled and main_index >= 192, enabled)
      math = Nx.select(fixed_fallback, band(math, 0xBF), math)
      color = Nx.select(enabled, blend(first, second, math), first)
      brightness = column(controls, 0)

      Nx.stack(
        [
          expand(band(color, 0x1F), brightness),
          expand(band(shr(color, 5), 0x1F), brightness),
          expand(band(shr(color, 10), 0x1F), brightness)
        ],
        axis: 2
      )
      |> Nx.as_type(:u8)
    end

    defnp mode7_background(vram, controls) do
      a = signed16(column(controls, 33))
      b = signed16(column(controls, 34))
      c = signed16(column(controls, 35))
      d = signed16(column(controls, 36))
      center_x = signed13(column(controls, 37))
      center_y = signed13(column(controls, 38))
      hofs = signed13(column(controls, 31))
      vofs = signed13(column(controls, 32))
      select = column(controls, 30)
      screen_y = Nx.iota({@height, 1}, type: :s32) + 1
      screen_y = Nx.select(band(select, 2) != 0, 255 - screen_y, screen_y)
      screen_x = Nx.iota({1, @width}, type: :s32) |> Nx.broadcast({@height, @width})
      screen_x = Nx.select(band(full_column(controls, 30), 1) != 0, 255 - screen_x, screen_x)
      xx = clip_mode7_offset(hofs - center_x)
      yy = clip_mode7_offset(vofs - center_y)
      row_x = band64(b * screen_y) + band64(b * yy) + center_x * 256
      row_y = band64(d * screen_y) + band64(d * yy) + center_y * 256
      texture_x = shr(a * screen_x + band64(a * xx) + row_x, 8)
      texture_y = shr(c * screen_x + band64(c * xx) + row_y, 8)
      in_bounds = texture_x >= 0 and texture_x < 1024 and texture_y >= 0 and texture_y < 1024
      x = band(texture_x, 0x3FF)
      y = band(texture_y, 0x3FF)
      tilemap_address = band(y, -8) * 32 + band(shr(x, 2), -2)

      tile =
        Nx.take(vram, Nx.flatten(tilemap_address))
        |> Nx.reshape({@height, @width})
        |> Nx.as_type(:s32)

      pixel_address = 1 + tile * 128 + band(y, 7) * 16 + band(x, 7) * 2

      color =
        Nx.take(vram, Nx.flatten(pixel_address))
        |> Nx.reshape({@height, @width})
        |> Nx.as_type(:s32)

      tile_zero_address = 1 + band(y, 7) * 16 + band(x, 7) * 2

      tile_zero_color =
        Nx.take(vram, Nx.flatten(tile_zero_address))
        |> Nx.reshape({@height, @width})
        |> Nx.as_type(:s32)

      repeat = band(shr(full_column(controls, 30), 6), 3)
      wrapped = repeat == 0 or repeat == 1
      color = Nx.select(wrapped or in_bounds, color, Nx.select(repeat == 3, tile_zero_color, 0))
      color
    end

    defnp compose_mode7(pixel, object_index, object_priority, screen, extbg) do
      bg1_opaque = pixel != 0 and band(screen, 1) != 0
      bg1_score = Nx.select(bg1_opaque, 3, 0)
      bg2_index = band(pixel, 0x7F)
      bg2_opaque = extbg != 0 and bg2_index != 0 and band(screen, 2) != 0
      bg2_score = Nx.select(band(pixel, 0x80) != 0, 5, 1)
      bg2_score = Nx.select(bg2_opaque, bg2_score, 0)
      bg2_wins = bg2_score > bg1_score
      bg_score = Nx.select(bg2_wins, bg2_score, bg1_score)
      bg_index = Nx.select(bg2_wins, bg2_index, pixel)
      bg_layer = Nx.select(bg2_wins, 1, 0)

      object_score =
        Nx.select(
          object_priority == 4,
          7,
          Nx.select(
            object_priority == 3,
            6,
            Nx.select(object_priority == 2, 4, Nx.select(object_priority == 1, 2, 0))
          )
        )

      object_score =
        Nx.select(object_priority > 0 and band(screen, 0x10) != 0, object_score, 0)

      object_wins = object_score > bg_score
      index = Nx.select(object_wins, object_index, Nx.select(bg_score > 0, bg_index, 0))
      layer = Nx.select(object_wins, 4, Nx.select(bg_score > 0, bg_layer, 5))
      {index, layer}
    end

    defnp mode7_direct_color(index) do
      band(index, 0x07) * 4 + band(index, 0x38) * 16 + band(index, 0xC0) * 128
    end

    defnp signed16(value) do
      value = band(value, 0xFFFF)
      Nx.select(band(value, 0x8000) != 0, value - 0x10000, value)
    end

    defnp signed13(value) do
      value = band(value, 0x1FFF)
      Nx.select(band(value, 0x1000) != 0, value - 0x2000, value)
    end

    defnp clip_mode7_offset(value) do
      Nx.select(band(value, 0x2000) != 0, bor(value, -0x400), band(value, 0x3FF))
    end

    defnp(band64(value), do: band(value, -64))

    defnp background(vram, controls, bg, bpp) do
      x = Nx.iota({1, @width}, type: :s32) + column(controls, 8 + bg)
      y = Nx.iota({@height, 1}, type: :s32) + column(controls, 11 + bg)
      x = band(x, 0x3FF)
      y = band(y, 0x3FF)
      tile_x = Nx.quotient(x, 8)
      tile_y = Nx.quotient(y, 8)
      sc = column(controls, 2 + bg)
      size = band(sc, 3)
      width = Nx.select(size == 1 or size == 3, 64, 32)
      tile_x = Nx.remainder(tile_x, width)
      tile_y = Nx.remainder(tile_y, Nx.select(size >= 2, 64, 32))
      screen_x = Nx.quotient(tile_x, 32)
      screen_y = Nx.quotient(tile_y, 32)
      screen_number = screen_x + screen_y * Nx.select(width == 64, 2, 1)

      word =
        band(sc, 0xFC) * 256 + screen_number * 0x400 + Nx.remainder(tile_y, 32) * 32 +
          Nx.remainder(tile_x, 32)

      low =
        Nx.take(vram, Nx.flatten(word * 2)) |> Nx.reshape({@height, @width}) |> Nx.as_type(:s32)

      high =
        Nx.take(vram, Nx.flatten(word * 2 + 1))
        |> Nx.reshape({@height, @width})
        |> Nx.as_type(:s32)

      entry = low + high * 256
      tile = band(entry, 0x3FF)
      px = Nx.remainder(x, 8)
      py = Nx.remainder(y, 8)
      px = Nx.select(band(entry, 0x4000) != 0, 7 - px, px)
      py = Nx.select(band(entry, 0x8000) != 0, 7 - py, py)
      bytes = if bpp == 4, do: 32, else: 16
      base = column(controls, 5 + bg) * 0x2000 + tile * bytes + py * 2
      bit = 7 - px
      p0 = gather_bit(vram, base, bit)
      p1 = gather_bit(vram, base + 1, bit)

      raw =
        if bpp == 4 do
          p0 + p1 * 2 + gather_bit(vram, base + 16, bit) * 4 +
            gather_bit(vram, base + 17, bit) * 8
        else
          p0 + p1 * 2
        end

      palette_stride = if bpp == 4, do: 16, else: 4
      index = band(shr(entry, 10), 7) * palette_stride + raw
      {index, band(shr(entry, 13), 1), raw != 0}
    end

    defnp compose(
            c0,
            c1,
            c2,
            r0,
            r1,
            r2,
            o0,
            o1,
            o2,
            object_index,
            object_priority,
            screen,
            screen_window,
            controls,
            bg3_high
          ) do
      e0 = o0 and band(screen, 1) != 0 and not layer_masked(controls, screen_window, 0)
      e1 = o1 and band(screen, 2) != 0 and not layer_masked(controls, screen_window, 1)
      e2 = o2 and band(screen, 4) != 0 and not layer_masked(controls, screen_window, 2)
      s0 = Nx.select(e0, r0, 0)
      s1 = Nx.select(e1, r1, 0)
      s2 = Nx.select(e2, r2, 0)

      bg_score = Nx.max(Nx.max(s0, s1), s2)

      bg_index =
        Nx.select(
          s0 >= s1 and s0 >= s2 and s0 > 0,
          c0,
          Nx.select(s1 >= s2 and s1 > 0, c1, Nx.select(s2 > 0, c2, 0))
        )

      bg_layer =
        Nx.select(
          s0 >= s1 and s0 >= s2 and s0 > 0,
          0,
          Nx.select(s1 >= s2 and s1 > 0, 1, Nx.select(s2 > 0, 2, 5))
        )

      object_score =
        Nx.select(
          bg3_high,
          Nx.select(
            object_priority == 4,
            9,
            Nx.select(object_priority == 3, 6, Nx.select(object_priority == 2, 3, 2))
          ),
          Nx.select(
            object_priority == 4,
            11,
            Nx.select(object_priority == 3, 8, Nx.select(object_priority == 2, 5, 2))
          )
        )

      object_visible =
        object_priority > 0 and band(screen, 0x10) != 0 and
          not layer_masked(controls, screen_window, 4)

      object_score = Nx.select(object_visible, object_score, 0)
      object_wins = object_score > bg_score
      {Nx.select(object_wins, object_index, bg_index), Nx.select(object_wins, 4, bg_layer)}
    end

    defnp compose_unwindowed(
            c0,
            c1,
            c2,
            r0,
            r1,
            r2,
            o0,
            o1,
            o2,
            object_index,
            object_priority,
            screen,
            bg3_high
          ) do
      s0 = Nx.select(o0 and band(screen, 1) != 0, r0, 0)
      s1 = Nx.select(o1 and band(screen, 2) != 0, r1, 0)
      s2 = Nx.select(o2 and band(screen, 4) != 0, r2, 0)
      bg_score = Nx.max(Nx.max(s0, s1), s2)

      bg_index =
        Nx.select(
          s0 >= s1 and s0 >= s2 and s0 > 0,
          c0,
          Nx.select(s1 >= s2 and s1 > 0, c1, Nx.select(s2 > 0, c2, 0))
        )

      bg_layer =
        Nx.select(
          s0 >= s1 and s0 >= s2 and s0 > 0,
          0,
          Nx.select(s1 >= s2 and s1 > 0, 1, Nx.select(s2 > 0, 2, 5))
        )

      object_score =
        Nx.select(
          bg3_high,
          Nx.select(
            object_priority == 4,
            9,
            Nx.select(object_priority == 3, 6, Nx.select(object_priority == 2, 3, 2))
          ),
          Nx.select(
            object_priority == 4,
            11,
            Nx.select(object_priority == 3, 8, Nx.select(object_priority == 2, 5, 2))
          )
        )

      object_score =
        Nx.select(object_priority > 0 and band(screen, 0x10) != 0, object_score, 0)

      object_wins = object_score > bg_score
      {Nx.select(object_wins, object_index, bg_index), Nx.select(object_wins, 4, bg_layer)}
    end

    defnp layer_masked(controls, screen_window, layer) do
      band(screen_window, 1 <<< layer) != 0 and window_mask(controls, layer)
    end

    defnp window_mask(controls, layer) do
      {config, logic} =
        case layer do
          0 ->
            {band(full_column(controls, 21), 0x0F), band(full_column(controls, 28), 3)}

          1 ->
            {shr(full_column(controls, 21), 4), band(shr(full_column(controls, 28), 2), 3)}

          2 ->
            {band(full_column(controls, 22), 0x0F), band(shr(full_column(controls, 28), 4), 3)}

          3 ->
            {shr(full_column(controls, 22), 4), band(shr(full_column(controls, 28), 6), 3)}

          4 ->
            {band(full_column(controls, 23), 0x0F), band(full_column(controls, 29), 3)}

          5 ->
            {shr(full_column(controls, 23), 4), band(shr(full_column(controls, 29), 2), 3)}
        end

      x = Nx.iota({1, @width}, type: :s32)
      w1_inside = x >= column(controls, 24) and x <= column(controls, 25)
      w2_inside = x >= column(controls, 26) and x <= column(controls, 27)
      w1 = Nx.select(band(config, 1) != 0, not w1_inside, w1_inside)
      w2 = Nx.select(band(config, 4) != 0, not w2_inside, w2_inside)
      w1_enabled = band(config, 2) != 0
      w2_enabled = band(config, 8) != 0

      combined =
        Nx.select(
          logic == 0,
          w1 or w2,
          Nx.select(logic == 1, w1 and w2, Nx.select(logic == 2, w1 != w2, w1 == w2))
        )

      Nx.select(
        w1_enabled and w2_enabled,
        combined,
        Nx.select(w1_enabled, w1, Nx.select(w2_enabled, w2, w1 and not w1))
      )
    end

    defnp window_mode_applies(mode, inside) do
      Nx.select(
        mode == 0,
        inside and not inside,
        Nx.select(mode == 1, not inside, Nx.select(mode == 2, inside, inside or not inside))
      )
    end

    defnp blend(first, second, math) do
      subtract = band(math, 0x80) != 0
      half = band(math, 0x40) != 0
      red = blend_component(first, second, subtract, half, 0)
      green = blend_component(first, second, subtract, half, 5)
      blue = blend_component(first, second, subtract, half, 10)
      red + green * 32 + blue * 1024
    end

    defnp blend_component(first, second, subtract, half, shift) do
      a = band(shr(first, shift), 0x1F)
      b = band(shr(second, shift), 0x1F)
      value = Nx.select(subtract, Nx.max(a - b, 0), Nx.min(a + b, 31))
      Nx.select(half, shr(value, 1), value)
    end

    defnp gather_bit(vram, address, bit) do
      byte =
        Nx.take(vram, Nx.flatten(address)) |> Nx.reshape({@height, @width}) |> Nx.as_type(:s32)

      band(shr(byte, bit), 1)
    end

    defnp expand(component, brightness) do
      scaled = Nx.quotient(component * brightness, 15)
      bor(Nx.left_shift(scaled, 3), shr(scaled, 2))
    end

    defnp column(tensor, index) do
      tensor[[.., index]] |> Nx.new_axis(1) |> Nx.broadcast({@height, 1})
    end

    defnp(full_column(tensor, index),
      do: Nx.broadcast(column(tensor, index), {@height, @width})
    )

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(bor(a, b), do: Nx.bitwise_or(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))

    defp states(%{scanline_states: states}) when is_list(states), do: Enum.reverse(states)

    defp states(ppu),
      do: [Beamicom.SNES.PPU.visual_state(ppu)]

    defp controls_tensor([row]) do
      row
      |> Nx.tensor(type: :s32)
      |> Nx.reshape({1, length(row)})
    end

    defp controls_tensor(rows), do: Nx.tensor(rows, type: :s32)

    defp vram_tensor(ppu) do
      key = {__MODULE__, :resident_vram, Beamicom.SNES.Nx.backend()}

      case Process.get(key) do
        {identity, version, tensor}
        when identity == ppu.cache_identity and version == ppu.vram_version ->
          tensor

        _other ->
          tensor =
            ppu.vram
            |> :array.to_list()
            |> :erlang.list_to_binary()
            |> Nx.from_binary(:u8)
            |> Nx.backend_copy(Beamicom.SNES.Nx.backend())

          Process.put(key, {ppu.cache_identity, ppu.vram_version, tensor})
          tensor
      end
    end

    defp compiled(args, variant) do
      key =
        {__MODULE__, :background_obj_v5, variant, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          function =
            case variant do
              variant when variant in [:mode1_windowed, :mode1_windowed_constant] ->
                &render_mode1/4

              variant when variant in [:mode1, :mode1_constant] ->
                &render_mode1_unwindowed/4

              variant when variant in [:mode7, :mode7_constant] ->
                &render_mode7/4
            end

          compiled = Beamicom.SNES.Nx.compile(function, args)

          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end
