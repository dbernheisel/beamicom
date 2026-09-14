if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.SNES.Nx.PPURenderer do
    @moduledoc "Frame-wide EXLA renderer for the common 256x224 Mode 1 background path."

    import Nx.Defn

    @width 256
    @height 224
    def supported?(ppu) do
      states = states(ppu)

      ppu.overscan? == false and length(states) == @height and
        Enum.uniq_by(states, &elem(&1, 20)) |> length() == 1 and
        Enum.all?(states, fn state ->
          elem(state, 2) == 1 and elem(state, 4) == 0
        end)
    end

    def render(ppu, object_layer) do
      states = states(ppu)

      controls =
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
            elem(elem(state, 12), 1)
          ]
        end)

      palette = states |> hd() |> elem(21) |> :array.to_list()

      args = [
        Nx.tensor(controls, type: :s32),
        vram_tensor(ppu),
        Nx.tensor(palette, type: :u16),
        object_layer |> Nx.from_binary(:u8) |> Nx.reshape({@height, @width, 2})
      ]

      windowed? =
        Enum.any?(states, fn state ->
          elem(state, 15) != 0 or elem(state, 16) != 0 or
            Bitwise.band(elem(state, 17), 0xF0) != 0
        end)

      compiled(args, windowed?) |> apply(args) |> Nx.to_binary()
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

      {sub_index, _sub_layer} =
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
      second = Nx.select(band(select, 2) != 0, sub_color, fixed)
      math = full_column(controls, 17)
      enabled = band(shr(math, main_layer), 1) != 0
      enabled = Nx.select(main_layer == 5, band(math, 0x20) != 0, enabled)
      enabled = Nx.select(main_layer == 4, enabled and main_index >= 192, enabled)
      color_window = window_mask(controls, 5)
      first = Nx.select(window_mode_applies(band(shr(select, 6), 3), color_window), 0, first)
      enabled = enabled and not window_mode_applies(band(shr(select, 4), 3), color_window)
      mixed = blend(first, second, math)
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
          0,
          controls,
          bg3_high
        )

      {sub_index, _sub_layer} =
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
          0,
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
      second = Nx.select(band(select, 2) != 0, sub_color, full_column(controls, 18))
      math = full_column(controls, 17)
      enabled = band(shr(math, main_layer), 1) != 0
      enabled = Nx.select(main_layer == 5, band(math, 0x20) != 0, enabled)
      enabled = Nx.select(main_layer == 4, enabled and main_index >= 192, enabled)
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
      w1 = Nx.select(band(config, 2) != 0, not w1_inside, w1_inside)
      w2 = Nx.select(band(config, 8) != 0, not w2_inside, w2_inside)
      w1_enabled = band(config, 1) != 0
      w2_enabled = band(config, 4) != 0

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

    defnp(expand(component, brightness), do: Nx.quotient(component * 255 * brightness, 31 * 15))
    defnp(column(tensor, index), do: tensor[[.., index]] |> Nx.reshape({@height, 1}))

    defnp(full_column(tensor, index),
      do: Nx.broadcast(column(tensor, index), {@height, @width})
    )

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))

    defp states(%{scanline_states: states}) when is_list(states), do: Enum.reverse(states)

    defp states(ppu),
      do: List.duplicate(Beamicom.SNES.PPU.visual_state(ppu), @height)

    defp vram_tensor(ppu) do
      key = {__MODULE__, :resident_vram}

      case Process.get(key) do
        {version, tensor} when version == ppu.vram_version ->
          tensor

        _other ->
          tensor =
            ppu.vram
            |> :array.to_list()
            |> :erlang.list_to_binary()
            |> Nx.from_binary(:u8)
            |> Nx.backend_copy({EXLA.Backend, client: :host})

          Process.put(key, {ppu.vram_version, tensor})
          tensor
      end
    end

    defp compiled(args, windowed?) do
      key = {__MODULE__, :mode1_background_obj_windows_v3, windowed?}

      case :persistent_term.get(key, nil) do
        nil ->
          function = if windowed?, do: &render_mode1/4, else: &render_mode1_unwindowed/4

          compiled =
            EXLA.compile(function, Enum.map(args, &Nx.to_template/1), client: :host)

          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end
