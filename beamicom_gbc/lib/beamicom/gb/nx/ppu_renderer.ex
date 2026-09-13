if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.GB.Nx.PPURenderer do
    @moduledoc """
    Frame-wide Game Boy renderer over frame-start PPU memory and timed writes.

    The live PPU sends a VRAM/OAM/palette snapshot, nine control bytes per
    scanline, and the memory writes that become visible during the frame. EXLA
    reconstructs scanline memory, performs tile-map lookup, evaluates all forty
    OAM entries, applies the first-ten rule, and composes all pixels.
    """

    import Nx.Defn
    @behaviour Beamicom.GB.PPURenderer

    @height 144
    @width 160
    @vram_size 0x4000
    @oam_size 160
    @palette_size 128
    @control_size 9
    @event_capacities [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]

    @impl true
    def prepare(model) when model in [:dmg, :cgb], do: nil

    @impl true
    def render(model, %{controls: controls, snapshot: snapshot, events: events}, state)
        when model in [:dmg, :cgb] and length(controls) == @height do
      {vram, oam, {bg_palette, obj_palette}} = snapshot

      base_args = [
        tensor(controls, {@height, @control_size}),
        tensor(Tuple.to_list(vram), {@vram_size}),
        tensor(oam, {@oam_size}),
        tensor(bg_palette <> obj_palette, {@palette_size})
      ]

      {kind, args} =
        case events do
          [] ->
            {static_kind(controls), base_args}

          events ->
            {event_rows, event_count, capacity} = pack_events(events)

            {capacity,
             base_args ++
               [Nx.tensor(event_rows, type: :s32), Nx.tensor(event_count, type: :s32)]}
        end

      frame = compiled(model, kind, args) |> apply(args)
      {Nx.to_binary(frame), state}
    end

    @doc "Apply the LCD Pixel Transparency presentation shader to a CGB RGB24 frame."
    def pixel_transparency(frame, output_size, options \\ []),
      do: Beamicom.GB.Nx.PixelTransparency.filter(frame, {@width, @height}, output_size, options)

    @doc "Tensor form of `pixel_transparency/3` for chaining resident Nx results."
    def pixel_transparency_tensor(frame, output_size, options \\ []),
      do: Beamicom.GB.Nx.PixelTransparency.filter_tensor(frame, output_size, options)

    defn render_dmg_static(controls, vram, oam, palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      render_dmg(controls, vram, oam, palettes, events, Nx.tensor(0, type: :s32))
    end

    defn render_cgb_static(controls, vram, oam, palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      render_cgb(controls, vram, oam, palettes, events, Nx.tensor(0, type: :s32))
    end

    defn render_dmg_background_static(controls, vram, _oam, _palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, _bg_attrs} = background_layer(vram, controls, events, Nx.tensor(0), false)
      lcdc = column(controls, 0) |> Nx.broadcast({@height, @width})
      bg_color = Nx.select(band(lcdc, 1) != 0, bg_color, 0)
      bgp = column(controls, 3)
      band(shr(bgp, bg_color * 2), 3) |> Nx.as_type(:u8)
    end

    defn render_cgb_background_static(controls, vram, _oam, palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, bg_attrs} = background_layer(vram, controls, events, Nx.tensor(0), true)
      colors = cgb_colors(palettes, events, Nx.tensor(0))
      palette_gather(colors, band(bg_attrs, 7) * 4 + bg_color)
    end

    defn render_dmg_no_sprites_static(controls, vram, _oam, _palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, _bg_attrs} = background(vram, controls, events, Nx.tensor(0), false)
      lcdc = column(controls, 0) |> Nx.broadcast({@height, @width})
      bg_color = Nx.select(band(lcdc, 1) != 0, bg_color, 0)
      bgp = column(controls, 3)
      band(shr(bgp, bg_color * 2), 3) |> Nx.as_type(:u8)
    end

    defn render_cgb_no_sprites_static(controls, vram, _oam, palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, bg_attrs} = background(vram, controls, events, Nx.tensor(0), true)
      colors = cgb_colors(palettes, events, Nx.tensor(0))
      palette_gather(colors, band(bg_attrs, 7) * 4 + bg_color)
    end

    defn render_dmg_no_window_static(controls, vram, oam, _palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, _bg_attrs} = background_layer(vram, controls, events, Nx.tensor(0), false)

      {object_color, object_attrs, occupied} =
        objects(vram, oam, controls, events, Nx.tensor(0), false)

      compose_dmg(bg_color, object_color, object_attrs, occupied, controls)
    end

    defn render_cgb_no_window_static(controls, vram, oam, palettes) do
      events = Nx.tensor([[0, 0, 0, 0]], type: :s32)
      {bg_color, bg_attrs} = background_layer(vram, controls, events, Nx.tensor(0), true)

      {object_color, object_attrs, occupied} =
        objects(vram, oam, controls, events, Nx.tensor(0), true)

      compose_cgb(
        bg_color,
        bg_attrs,
        object_color,
        object_attrs,
        occupied,
        controls,
        cgb_colors(palettes, events, Nx.tensor(0))
      )
    end

    defn render_dmg(controls, vram, oam, _palettes, events, event_count) do
      {bg_color, _bg_attrs} = background(vram, controls, events, event_count, false)

      {object_color, object_attrs, occupied} =
        objects(vram, oam, controls, events, event_count, false)

      compose_dmg(bg_color, object_color, object_attrs, occupied, controls)
    end

    defnp compose_dmg(bg_color, object_color, object_attrs, occupied, controls) do
      lcdc = column(controls, 0) |> Nx.broadcast({@height, @width})
      bg_color = Nx.select(band(lcdc, 1) != 0, bg_color, 0)
      bgp = column(controls, 3)
      obp0 = column(controls, 4)
      obp1 = column(controls, 5)
      bg = band(shr(bgp, bg_color * 2), 3)
      object_palette = Nx.select(band(object_attrs, 0x10) != 0, obp1, obp0)
      object = band(shr(object_palette, object_color * 2), 3)
      behind_background = band(object_attrs, 0x80) != 0 and bg_color != 0
      Nx.select(occupied and not behind_background, object, bg) |> Nx.as_type(:u8)
    end

    defn render_cgb(controls, vram, oam, palettes, events, event_count) do
      {bg_color, bg_attrs} = background(vram, controls, events, event_count, true)

      {object_color, object_attrs, occupied} =
        objects(vram, oam, controls, events, event_count, true)

      compose_cgb(
        bg_color,
        bg_attrs,
        object_color,
        object_attrs,
        occupied,
        controls,
        cgb_colors(palettes, events, event_count)
      )
    end

    defnp compose_cgb(bg_color, bg_attrs, object_color, object_attrs, occupied, controls, colors) do
      bg_index = band(bg_attrs, 7) * 4 + bg_color
      object_index = 32 + band(object_attrs, 7) * 4 + object_color
      bg = palette_gather(colors, bg_index)
      object = palette_gather(colors, object_index)
      lcdc = column(controls, 0)

      priority =
        band(lcdc, 1) != 0 and bg_color != 0 and
          (band(bg_attrs, 0x80) != 0 or band(object_attrs, 0x80) != 0)

      visible =
        (occupied and not priority) |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})

      Nx.select(visible, object, bg)
    end

    defnp background(vram, controls, events, event_count, cgb?) do
      line = Nx.iota({@height, @width}, axis: 0, type: :s32)
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      lcdc = column(controls, 0)
      wy = column(controls, 6)
      wx = column(controls, 7)
      window_line = column(controls, 8)

      {bg_color, bg_attrs} = background_layer(vram, controls, events, event_count, cgb?)

      window_x = wx - 7
      window_map = Nx.select(band(lcdc, 0x40) == 0, 0x1800, 0x1C00)

      {window_color, window_attrs} =
        tile(
          vram,
          window_map,
          Nx.max(x - window_x, 0),
          window_line,
          lcdc,
          events,
          event_count,
          cgb?
        )

      visible =
        band(lcdc, 0x20) != 0 and line >= wy and window_x < @width and x >= window_x

      {Nx.select(visible, window_color, bg_color), Nx.select(visible, window_attrs, bg_attrs)}
    end

    defnp background_layer(vram, controls, events, event_count, cgb?) do
      line = Nx.iota({@height, @width}, axis: 0, type: :s32)
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      lcdc = column(controls, 0)
      bg_y = band(line + column(controls, 1), 0xFF)
      bg_x = band(x + column(controls, 2), 0xFF)
      bg_map = Nx.select(band(lcdc, 0x08) == 0, 0x1800, 0x1C00)
      tile(vram, bg_map, bg_x, bg_y, lcdc, events, event_count, cgb?)
    end

    defnp tile(vram, map, source_x, source_y, lcdc, events, event_count, cgb?) do
      lcdc = Nx.broadcast(lcdc, {@height, @width})

      map_address =
        map + band(Nx.quotient(source_y, 8), 0x1F) * 32 +
          band(Nx.quotient(source_x, 8), 0x1F)

      lines = Nx.iota({@height, @width}, axis: 0, type: :s32)
      tile_number = timed_read(vram, map_address, lines, 0, events, event_count)

      attrs =
        if cgb?,
          do: timed_read(vram, map_address + 0x2000, lines, 0, events, event_count),
          else: Nx.broadcast(0, {@height, @width})

      row = band(source_y, 7)
      row = Nx.select(cgb? and band(attrs, 0x40) != 0, 7 - row, row)
      unsigned = tile_number * 16
      signed = Nx.select(tile_number < 128, 0x1000 + unsigned, unsigned)
      tile_address = Nx.select(band(lcdc, 0x10) != 0, unsigned, signed)
      tile_address = tile_address + Nx.select(cgb? and band(attrs, 0x08) != 0, 0x2000, 0)
      low = timed_read(vram, tile_address + row * 2, lines, 0, events, event_count)
      high = timed_read(vram, tile_address + row * 2 + 1, lines, 0, events, event_count)
      pixel = band(source_x, 7)
      bit = Nx.select(cgb? and band(attrs, 0x20) != 0, pixel, 7 - pixel)
      {bor(band(shr(low, bit), 1), band(shr(high, bit), 1) * 2), attrs}
    end

    defnp objects(vram, oam, controls, events, event_count, cgb?) do
      oam_addresses = Nx.iota({@height, @oam_size}, axis: 1, type: :s32)
      oam_lines = Nx.iota({@height, @oam_size}, axis: 0, type: :s32)

      sprites =
        timed_read(oam, oam_addresses, oam_lines, 1, events, event_count)
        |> Nx.reshape({@height, 40, 4})

      y = sprites[[.., .., 0]] - 16
      raw_x = sprites[[.., .., 1]]
      left = raw_x - 8
      tile_number = sprites[[.., .., 2]]
      attrs = sprites[[.., .., 3]]
      line = Nx.iota({@height, 40}, axis: 0, type: :s32)
      height = Nx.select(band(column(controls, 0), 0x04) == 0, 8, 16)
      height = Nx.broadcast(height, {@height, 40})
      in_range = line >= y and line < y + height
      selected = Nx.cumulative_sum(Nx.as_type(in_range, :s32), axis: 1) <= 10 and in_range

      source_y = line - y
      source_y = Nx.select(band(attrs, 0x40) != 0, height - 1 - source_y, source_y)

      tile_number =
        Nx.select(
          height == 8,
          tile_number,
          band(tile_number, 0xFE) + Nx.quotient(source_y, 8)
        )

      address = tile_number * 16 + band(source_y, 7) * 2
      address = address + Nx.select(cgb? and band(attrs, 0x08) != 0, 0x2000, 0)
      sprite_lines = Nx.iota({@height, 40}, axis: 0, type: :s32)
      low = timed_read(vram, address, sprite_lines, 0, events, event_count)
      high = timed_read(vram, address + 1, sprite_lines, 0, events, event_count)

      x = Nx.iota({@height, 40, @width}, axis: 2, type: :s32)
      source_x = x - Nx.new_axis(left, 2)
      safe_x = Nx.clip(source_x, 0, 7)
      attrs3 = Nx.new_axis(attrs, 2) |> Nx.broadcast({@height, 40, @width})
      bit = Nx.select(band(attrs3, 0x20) != 0, safe_x, 7 - safe_x)

      color =
        bor(
          band(shr(Nx.new_axis(low, 2), bit), 1),
          band(shr(Nx.new_axis(high, 2), bit), 1) * 2
        )

      enabled = (band(column(controls, 0), 0x02) != 0) |> Nx.new_axis(1)

      visible =
        Nx.new_axis(selected, 2) and enabled and source_x >= 0 and source_x < 8 and color != 0

      indexes = Nx.iota({@height, 40}, axis: 1, type: :s32)
      score = if cgb?, do: indexes, else: raw_x * 64 + indexes
      score = Nx.new_axis(score, 2) |> Nx.broadcast({@height, 40, @width})
      winner = Nx.argmin(Nx.select(visible, score, 1_000_000), axis: 1) |> Nx.new_axis(1)
      color = Nx.take_along_axis(color, winner, axis: 1) |> Nx.squeeze(axes: [1])

      attrs =
        Nx.take_along_axis(Nx.broadcast(attrs3, {@height, 40, @width}), winner, axis: 1)
        |> Nx.squeeze(axes: [1])

      {color, attrs, Nx.any(visible, axes: [1])}
    end

    defnp timed_read(memory, addresses, lines, kind, events, event_count) do
      addresses = Nx.as_type(addresses, :s32)
      values = Nx.take(memory, addresses) |> Nx.as_type(:s32)

      {_, values, _, _, _, _} =
        while {index = Nx.tensor(0, type: :s32), values, addresses, lines, events, event_count},
              index < event_count do
          event = events[index]
          active = event[1] == kind and lines >= event[0] and addresses == event[2]
          values = Nx.select(active, event[3], values)
          {index + 1, values, addresses, lines, events, event_count}
        end

      values
    end

    defnp palette_gather(palettes, indexes) do
      indexes = indexes |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})
      Nx.take_along_axis(palettes, indexes, axis: 1)
    end

    defnp cgb_colors(palettes, events, event_count) do
      palette_addresses = Nx.iota({@height, @palette_size}, axis: 1, type: :s32)
      palette_lines = Nx.iota({@height, @palette_size}, axis: 0, type: :s32)

      palettes =
        timed_read(palettes, palette_addresses, palette_lines, 2, events, event_count)

      low = palettes[[.., 0..126//2]] |> Nx.as_type(:s32)
      high = palettes[[.., 1..127//2]] |> Nx.as_type(:s32)
      packed = low + high * 256

      Nx.stack(
        [
          expand5(band(packed, 0x1F)),
          expand5(band(shr(packed, 5), 0x1F)),
          expand5(band(shr(packed, 10), 0x1F))
        ],
        axis: 2
      )
      |> Nx.as_type(:u8)
    end

    defnp(expand5(component), do: component * 8 + shr(component, 2))

    defnp(column(tensor, index),
      do: tensor[[.., index]] |> Nx.reshape({@height, 1}) |> Nx.as_type(:s32)
    )

    defp tensor(data, shape),
      do: data |> IO.iodata_to_binary() |> Nx.from_binary(:u8) |> Nx.reshape(shape)

    defp pack_events(events) do
      count = length(events)

      capacity =
        Enum.find(@event_capacities, &(&1 >= count)) ||
          raise("too many visible PPU writes in one frame: #{count}")

      rows = Enum.map(events, &Tuple.to_list/1) ++ List.duplicate([0, 0, 0, 0], capacity - count)
      {rows, count, capacity}
    end

    defp compiled(model, kind, args) do
      key = {__MODULE__, model, kind, :frame_memory_v2}

      case :persistent_term.get(key, nil) do
        nil ->
          function =
            case {model, kind} do
              {:dmg, :static} -> &render_dmg_static/4
              {:cgb, :static} -> &render_cgb_static/4
              {:dmg, :background_static} -> &render_dmg_background_static/4
              {:cgb, :background_static} -> &render_cgb_background_static/4
              {:dmg, :no_sprites_static} -> &render_dmg_no_sprites_static/4
              {:cgb, :no_sprites_static} -> &render_cgb_no_sprites_static/4
              {:dmg, :no_window_static} -> &render_dmg_no_window_static/4
              {:cgb, :no_window_static} -> &render_cgb_no_window_static/4
              {:dmg, _capacity} -> &render_dmg/6
              {:cgb, _capacity} -> &render_cgb/6
            end

          compiled = EXLA.compile(function, Enum.map(args, &Nx.to_template/1), client: :host)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp static_kind(controls) do
      sprites? =
        Enum.any?(controls, fn <<lcdc, _rest::binary>> -> Bitwise.band(lcdc, 0x02) != 0 end)

      window? =
        Enum.any?(controls, fn <<lcdc, _rest::binary>> -> Bitwise.band(lcdc, 0x20) != 0 end)

      case {sprites?, window?} do
        {false, false} -> :background_static
        {false, true} -> :no_sprites_static
        {true, false} -> :no_window_static
        {true, true} -> :static
      end
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(bor(a, b), do: Nx.bitwise_or(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))
  end
end
