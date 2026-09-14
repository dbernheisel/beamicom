if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.PPURenderer do
    @moduledoc """
    Adaptive frame-wide NES pixel compositor.

    Immutable CHR ROM is decoded into a backend-resident tile atlas at cartridge
    load. CHR RAM and mapper-sensitive cases automatically use byte or hybrid
    capture inside the same renderer.
    """

    import Nx.Defn

    @height 240
    @width 256
    @lighting_scale 2
    @lighting_height div(@height, @lighting_scale)
    @lighting_width div(@width, @lighting_scale)
    @tiles 33
    @sprites 8
    @compiled_key {__MODULE__, :compiled}

    def prepare_chr(chr), do: prepare_chr(chr, [])

    def prepare_chr(chr, options) when is_list(options) do
      atlas = prepare_chr_atlas(chr)

      case prepare_lighting(chr, Keyword.get(options, :lighting)) do
        nil -> atlas
        lighting -> %{atlas: atlas, lighting: lighting}
      end
    end

    @doc false
    def atlas_state(%{atlas: atlas}), do: atlas
    def atlas_state(atlas), do: atlas

    def prepare_chr_atlas(<<>>), do: nil

    def prepare_chr_atlas(chr) do
      key =
        {__MODULE__, :chr_atlas, Beamicom.NES.Nx.backend(), :crypto.hash(:sha256, chr)}

      case :persistent_term.get(key, nil) do
        nil ->
          atlas =
            chr |> decode_chr() |> Nx.from_binary(:u8) |> Nx.reshape({div(byte_size(chr), 2), 8})

          atlas = Nx.backend_copy(atlas, Beamicom.NES.Nx.backend())
          :persistent_term.put(key, atlas)

        _atlas ->
          :ok
      end

      key
    end

    defp prepare_lighting(_chr, lighting) when lighting in [nil, false], do: nil

    defp prepare_lighting(chr, lighting) when is_list(lighting) do
      emitters = Keyword.get(lighting, :emitters, [])

      if emitters == [] or not Keyword.get(lighting, :enabled, true) do
        nil
      else
        rules = Enum.map(emitters, &normalize_emitter!/1)
        radius = Keyword.get(lighting, :radius, 6)
        sigma = Keyword.get(lighting, :sigma, max(radius / 2, 0.5))
        strength = Keyword.get(lighting, :strength, 1.0)

        unless is_integer(radius) and radius in 1..24,
          do: raise(ArgumentError, "lighting :radius must be an integer from 1 through 24")

        unless is_number(sigma) and sigma > 0,
          do: raise(ArgumentError, "lighting :sigma must be greater than zero")

        unless is_number(strength) and strength >= 0,
          do: raise(ArgumentError, "lighting :strength must be non-negative")

        chr_tiles = max(div(byte_size(chr), 16), 1)

        blur_radius = max(div(radius + @lighting_scale - 1, @lighting_scale), 1)
        blur_sigma = max(sigma / @lighting_scale, 0.5)

        %{
          ppu_lut: lighting_lut(512, rules, :ppu),
          chr_lut: lighting_lut(chr_tiles, rules, :chr),
          kernel_horizontal: gaussian_kernel(blur_radius, blur_sigma, :horizontal),
          kernel_vertical: gaussian_kernel(blur_radius, blur_sigma, :vertical),
          strength:
            strength
            |> Nx.tensor(type: :f32)
            |> Nx.backend_copy(Beamicom.NES.Nx.backend())
        }
      end
    end

    defp prepare_lighting(_chr, _lighting) do
      raise ArgumentError, "Nx PPU :lighting must be false, nil, or a keyword list"
    end

    defp normalize_emitter!(emitter) when is_list(emitter) do
      layer = Keyword.get(emitter, :layer, :sprite)
      tile_space = Keyword.get(emitter, :tile_space, :ppu)
      tiles = emitter |> Keyword.fetch!(:tiles) |> List.wrap()
      slots = emitter |> Keyword.get(:color_slots, [1, 2, 3]) |> List.wrap()
      subpalettes = emitter |> Keyword.get(:subpalettes, [0, 1, 2, 3]) |> List.wrap()
      intensity = Keyword.get(emitter, :intensity, 1.0)
      flicker = emitter |> Keyword.get(:flicker, false) |> normalize_flicker!()

      unless layer == :sprite,
        do: raise(ArgumentError, "Nx PPU lighting currently supports only sprite emitters")

      unless tile_space in [:ppu, :chr],
        do: raise(ArgumentError, "emitter :tile_space must be :ppu or :chr")

      unless tiles != [] and Enum.all?(tiles, &(is_integer(&1) and &1 >= 0)),
        do: raise(ArgumentError, "emitter :tiles must contain non-negative tile IDs")

      unless slots != [] and Enum.all?(slots, &(&1 in 1..3)),
        do: raise(ArgumentError, "emitter :color_slots must contain pattern colors 1 through 3")

      unless subpalettes != [] and Enum.all?(subpalettes, &(&1 in 0..3)),
        do: raise(ArgumentError, "emitter :subpalettes must contain values 0 through 3")

      unless is_number(intensity) and intensity >= 0 and intensity <= 1,
        do: raise(ArgumentError, "emitter :intensity must be between 0 and 1")

      %{
        tile_space: tile_space,
        tiles: MapSet.new(tiles),
        slots: MapSet.new(slots),
        subpalettes: MapSet.new(subpalettes),
        intensity: round(intensity * 255),
        flicker: round(flicker * 255)
      }
    end

    defp normalize_emitter!(_emitter) do
      raise ArgumentError, "each Nx PPU lighting emitter must be a keyword list"
    end

    defp normalize_flicker!(flicker) when flicker in [false, nil], do: 0.0
    defp normalize_flicker!(flicker) when flicker in [true, :organic], do: 0.18

    defp normalize_flicker!(flicker) when is_list(flicker),
      do: flicker |> Keyword.get(:amount, 0.18) |> normalize_flicker!()

    defp normalize_flicker!(amount) when is_number(amount) and amount >= 0 and amount <= 1,
      do: amount * 1.0

    defp normalize_flicker!(_flicker) do
      raise ArgumentError,
            "emitter :flicker must be false, :organic, or an amount from 0 through 1"
    end

    defp lighting_lut(tile_count, rules, tile_space) do
      values =
        for tile <- 0..(tile_count - 1), subpalette <- 0..3, slot <- 0..3 do
          {intensity, flicker} =
            rules
            |> Enum.filter(&(&1.tile_space == tile_space))
            |> Enum.reduce({0, 0}, fn rule, {intensity, flicker} ->
              if MapSet.member?(rule.tiles, tile) and MapSet.member?(rule.subpalettes, subpalette) and
                   MapSet.member?(rule.slots, slot),
                 do: {max(intensity, rule.intensity), max(flicker, rule.flicker)},
                 else: {intensity, flicker}
            end)

          intensity + flicker * 256
        end

      values
      |> Nx.tensor(type: :u16)
      |> Nx.reshape({tile_count, 4, 4})
      |> Nx.backend_copy(Beamicom.NES.Nx.backend())
    end

    defp gaussian_kernel(radius, sigma, direction) do
      weights =
        for x <- -radius..radius do
          :math.exp(-(x * x) / (2 * sigma * sigma))
        end

      total = Enum.sum(weights)
      weights = Enum.map(weights, &(&1 / total))
      size = radius * 2 + 1

      shape = if direction == :horizontal, do: {1, 1, 1, size}, else: {1, 1, size, 1}

      weights
      |> Nx.tensor(type: :f32)
      |> Nx.reshape(shape)
      |> Nx.backend_copy(Beamicom.NES.Nx.backend())
    end

    defp atlas_key(%{atlas: atlas}), do: atlas
    defp atlas_key(atlas), do: atlas

    @doc false
    def lighting_state(%{lighting: lighting}), do: lighting
    def lighting_state(_state), do: nil

    @doc false
    def sprite_lighting?(state), do: lighting_state(state) != nil

    defp lighting_args(lighting, :ppu),
      do: [lighting.ppu_lut]

    defp lighting_args(lighting, :chr),
      do: [lighting.chr_lut]

    def render(lines, palette, grayscale, edge_mask, renderer_state),
      do: render(lines, palette, grayscale, edge_mask, renderer_state, 0)

    def render(lines, palette, grayscale, edge_mask, renderer_state, frame_number)
        when length(lines) == @height do
      {kind, args} = render_args(lines, palette, grayscale, edge_mask, renderer_state)

      case compiled(kind, args, :rgb) |> apply(args) do
        {pixels, rgb} ->
          {Nx.to_binary(pixels), Nx.to_binary(rgb)}

        {pixels, rgb, emission} ->
          lighting = lighting_state(renderer_state)
          rgb = Nx.to_binary(rgb)
          emission = Nx.to_binary(emission)

          rgb =
            if emission == :binary.copy(<<0>>, @height * @width * 3) do
              rgb
            else
              emission
              |> tensor({@height, @width, 3})
              |> apply_lighting_tensor(
                edge_mask,
                lighting,
                frame_number,
                tensor(rgb, {@height, @width, 3})
              )
              |> Nx.to_binary()
            end

          {Nx.to_binary(pixels), rgb}
      end
    end

    @doc false
    def render_lighting_tensors(
          lines,
          palette,
          grayscale,
          edge_mask,
          renderer_state
        )
        when length(lines) == @height do
      {kind, args} = render_args(lines, palette, grayscale, edge_mask, renderer_state)

      case compiled(kind, args, :rgb) |> apply(args) do
        {pixels, rgb, emission} -> {pixels, rgb, emission}
        {_pixels, _rgb} -> raise ArgumentError, "renderer state does not enable sprite lighting"
      end
    end

    @doc false
    def apply_lighting_tensor(emission, edge_mask, lighting, frame_number, rgb) do
      args = [
        emission,
        tensor(Beamicom.NES.Palette.master_binary(), {64, 3}),
        lighting.kernel_horizontal,
        lighting.kernel_vertical,
        lighting.strength,
        Nx.tensor(edge_mask, type: :u8),
        Nx.tensor(frame_number, type: :u32),
        rgb
      ]

      compiled(:lighting, args, :rgb) |> apply(args)
    end

    @doc false
    def render_composed(pixels, palette, masks, edge_mask, _renderer_state, frame_number) do
      grayscale = Enum.any?(:binary.bin_to_list(masks), &(Bitwise.band(&1, 0x01) != 0))

      frame = %Beamicom.NES.Framebuffer{
        number: frame_number,
        pixels: pixels,
        palette: palette,
        edge_mask: edge_mask,
        grayscale: grayscale
      }

      {pixels, Beamicom.NES.Palette.to_rgb(frame)}
    end

    @doc false
    def render_composed_lit(
          pixels,
          palette,
          masks,
          provenance,
          edge_mask,
          renderer_state,
          frame_number
        ) do
      grayscale = Enum.any?(:binary.bin_to_list(masks), &(Bitwise.band(&1, 0x01) != 0))

      frame = %Beamicom.NES.Framebuffer{
        number: frame_number,
        pixels: pixels,
        palette: palette,
        edge_mask: edge_mask,
        grayscale: grayscale
      }

      rgb = Beamicom.NES.Palette.to_rgb(frame)

      emission =
        composed_emission_tensor(pixels, palette, grayscale, provenance, renderer_state)

      rgb =
        if Nx.to_binary(emission) == :binary.copy(<<0>>, @height * @width * 3) do
          rgb
        else
          emission
          |> apply_lighting_tensor(
            edge_mask,
            lighting_state(renderer_state),
            frame_number,
            tensor(rgb, {@height, @width, 3})
          )
          |> Nx.to_binary()
        end

      {pixels, rgb}
    end

    @doc false
    def composed_emission_tensor(pixels, palette, grayscale, provenance, renderer_state) do
      args = [
        tensor(pixels, {@height, @width}),
        tensor(palette, {32}),
        Nx.tensor(if(grayscale, do: 0x30, else: 0x3F), type: :u8),
        tensor(provenance, {@height, @width}, :u16),
        lighting_state(renderer_state).ppu_lut
      ]

      compiled(:provenance, args, :emission) |> apply(args)
    end

    @doc false
    def render_pixels_tensor(lines, _palette, _grayscale, _edge_mask, renderer_state)
        when length(lines) == @height do
      {pixels, _masks} = render_pixels_and_masks_tensor(lines, renderer_state)
      pixels
    end

    @doc false
    def render_pixels_and_masks_tensor(lines, renderer_state) when length(lines) == @height do
      {kind, args} = render_pixels_args(lines, renderer_state)
      pixels = compiled(kind, args, :pixels) |> apply(args)

      mask_index =
        case kind do
          :bytes -> 4
          :atlas -> 3
          :hybrid -> 6
        end

      {pixels, Enum.at(args, mask_index)}
    end

    defp render_pixels_args(lines, renderer_state) do
      atlas_key = atlas_key(renderer_state)

      cond do
        atlas_key == nil ->
          {lo, hi, attr, fine_x, mask, sx, _stile, slo, shi, sattr, svalid} =
            pack_bytes(lines)

          {:bytes,
           [
             tensor(lo, {@height, @tiles}),
             tensor(hi, {@height, @tiles}),
             tensor(attr, {@height, @tiles}),
             tensor(fine_x, {@height, 1}),
             tensor(mask, {@height, 1}),
             tensor(sx, {@height, @sprites}),
             tensor(slo, {@height, @sprites}),
             tensor(shi, {@height, @sprites}),
             tensor(sattr, {@height, @sprites}),
             tensor(svalid, {@height, @sprites})
           ]}

        atlas_only?(lines) ->
          {attr, refs, fine_x, mask, sx, sprite_refs, sattr, svalid} = pack_atlas(lines)

          {:atlas,
           [
             tensor(attr, {@height, @tiles}),
             tensor(refs, {@height, @tiles}, :u32),
             tensor(fine_x, {@height, 1}),
             tensor(mask, {@height, 1}),
             tensor(sx, {@height, @sprites}),
             tensor(sprite_refs, {@height, @sprites}, :u32),
             tensor(sattr, {@height, @sprites}),
             tensor(svalid, {@height, @sprites}),
             atlas(atlas_key)
           ]}

        true ->
          {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, _stile, slo, shi, sattr, svalid} =
            pack_hybrid(lines)

          {:hybrid,
           [
             tensor(lo, {@height, @tiles}),
             tensor(hi, {@height, @tiles}),
             tensor(attr, {@height, @tiles}),
             tensor(refs, {@height, @tiles}, :u32),
             tensor(bg_mode, {@height, 1}),
             tensor(fine_x, {@height, 1}),
             tensor(mask, {@height, 1}),
             tensor(sx, {@height, @sprites}),
             tensor(slo, {@height, @sprites}),
             tensor(shi, {@height, @sprites}),
             tensor(sattr, {@height, @sprites}),
             tensor(svalid, {@height, @sprites}),
             atlas(atlas_key)
           ]}
      end
    end

    defp render_args(lines, palette, grayscale, edge_mask, renderer_state) do
      atlas_key = atlas_key(renderer_state)
      lighting = lighting_state(renderer_state)

      common = [
        tensor(palette, {32}),
        tensor(Beamicom.NES.Palette.master_binary(), {64, 3}),
        Nx.tensor(if(grayscale, do: 0x30, else: 0x3F), type: :u8),
        Nx.tensor(edge_mask, type: :u8)
      ]

      cond do
        atlas_key == nil ->
          {lo, hi, attr, fine_x, mask, sx, stile, slo, shi, sattr, svalid} =
            pack_bytes(lines)

          args = [
            tensor(lo, {@height, @tiles}),
            tensor(hi, {@height, @tiles}),
            tensor(attr, {@height, @tiles}),
            tensor(fine_x, {@height, 1}),
            tensor(mask, {@height, 1}),
            tensor(sx, {@height, @sprites})
          ]

          if lighting do
            {:bytes_lit,
             args ++
               [
                 tensor(stile, {@height, @sprites}, :u16),
                 tensor(slo, {@height, @sprites}),
                 tensor(shi, {@height, @sprites}),
                 tensor(sattr, {@height, @sprites}),
                 tensor(svalid, {@height, @sprites})
               ] ++ common ++ lighting_args(lighting, :ppu)}
          else
            {:bytes,
             args ++
               [
                 tensor(slo, {@height, @sprites}),
                 tensor(shi, {@height, @sprites}),
                 tensor(sattr, {@height, @sprites}),
                 tensor(svalid, {@height, @sprites})
               ] ++ common}
          end

        atlas_only?(lines) ->
          {attr, refs, fine_x, mask, sx, sprite_refs, sattr, svalid} = pack_atlas(lines)

          args = [
            tensor(attr, {@height, @tiles}),
            tensor(refs, {@height, @tiles}, :u32),
            tensor(fine_x, {@height, 1}),
            tensor(mask, {@height, 1}),
            tensor(sx, {@height, @sprites}),
            tensor(sprite_refs, {@height, @sprites}, :u32),
            tensor(sattr, {@height, @sprites}),
            tensor(svalid, {@height, @sprites})
          ]

          if lighting do
            {:atlas_lit, args ++ common ++ [atlas(atlas_key)] ++ lighting_args(lighting, :chr)}
          else
            {:atlas, args ++ common ++ [atlas(atlas_key)]}
          end

        true ->
          {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, stile, slo, shi, sattr, svalid} =
            pack_hybrid(lines)

          args = [
            tensor(lo, {@height, @tiles}),
            tensor(hi, {@height, @tiles}),
            tensor(attr, {@height, @tiles}),
            tensor(refs, {@height, @tiles}, :u32),
            tensor(bg_mode, {@height, 1}),
            tensor(fine_x, {@height, 1}),
            tensor(mask, {@height, 1}),
            tensor(sx, {@height, @sprites})
          ]

          if lighting do
            {:hybrid_lit,
             args ++
               [
                 tensor(stile, {@height, @sprites}, :u16),
                 tensor(slo, {@height, @sprites}),
                 tensor(shi, {@height, @sprites}),
                 tensor(sattr, {@height, @sprites}),
                 tensor(svalid, {@height, @sprites})
               ] ++ common ++ [atlas(atlas_key)] ++ lighting_args(lighting, :ppu)}
          else
            {:hybrid,
             args ++
               [
                 tensor(slo, {@height, @sprites}),
                 tensor(shi, {@height, @sprites}),
                 tensor(sattr, {@height, @sprites}),
                 tensor(svalid, {@height, @sprites})
               ] ++ common ++ [atlas(atlas_key)]}
          end
      end
    end

    defn compose_bytes_pixels(
           lo,
           hi,
           attr,
           fine_x,
           mask,
           sx,
           slo,
           shi,
           sattr,
           svalid
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bit = 7 - band(source_x, 7)
      bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
      bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
      pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)

      compose_pixel_plane(pattern, bg_attr, x, mask, sx, slo, shi, sattr, svalid)
    end

    defn compose_bytes(
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

      compose_pixels(
        pattern,
        bg_attr,
        x,
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
      )
    end

    defn compose_bytes_lit(
           lo,
           hi,
           attr,
           fine_x,
           mask,
           sx,
           stile,
           slo,
           shi,
           sattr,
           svalid,
           palette,
           master,
           color_mask,
           edge_mask,
           emitter_lut
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bit = 7 - band(source_x, 7)
      bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
      bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
      pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)

      compose_pixels_lit(
        pattern,
        bg_attr,
        x,
        mask,
        sx,
        stile,
        slo,
        shi,
        sattr,
        svalid,
        palette,
        master,
        color_mask,
        edge_mask,
        emitter_lut
      )
    end

    defnp compose_pixels_atlas(
            pattern,
            bg_attr,
            x,
            mask,
            sx,
            sprite_refs,
            sattr,
            svalid,
            palette,
            master,
            color_mask,
            edge_mask,
            atlas
          ) do
      pixels =
        compose_pixel_plane_atlas(
          pattern,
          bg_attr,
          x,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas
        )

      finish_rgb(pixels, x, palette, master, color_mask, edge_mask)
    end

    defnp compose_pixel_plane_atlas(
            pattern,
            bg_attr,
            x,
            mask,
            sx,
            sprite_refs,
            sattr,
            svalid,
            atlas
          ) do
      bg =
        Nx.select(
          pattern == 0 or band(mask, 8) == 0 or (x < 8 and band(mask, 2) == 0),
          0,
          bg_attr * 4 + pattern
        )

      sprite = Nx.broadcast(0, {@height, @width + 1})
      sprite = scatter_sprite_atlas(sprite, 7, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 6, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 5, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 4, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 3, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 2, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 1, mask, sx, sprite_refs, sattr, svalid, atlas)
      sprite = scatter_sprite_atlas(sprite, 0, mask, sx, sprite_refs, sattr, svalid, atlas)
      finish_pixel_plane(bg, sprite)
    end

    defnp compose_pixel_plane_atlas_lit(
            pattern,
            bg_attr,
            x,
            mask,
            sx,
            sprite_refs,
            sattr,
            svalid,
            atlas,
            emitter_lut
          ) do
      bg =
        Nx.select(
          pattern == 0 or band(mask, 8) == 0 or (x < 8 and band(mask, 2) == 0),
          0,
          bg_attr * 4 + pattern
        )

      sprite = Nx.broadcast(0, {@height, @width + 1})

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          7,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          6,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          5,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          4,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          3,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          2,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          1,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      sprite =
        scatter_sprite_atlas_lit(
          sprite,
          0,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      finish_pixel_plane_lit(bg, sprite)
    end

    defn compose_atlas(
           attr,
           refs,
           fine_x,
           mask,
           sx,
           sprite_refs,
           sattr,
           svalid,
           palette,
           master,
           color_mask,
           edge_mask,
           atlas
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      column = band(source_x, 7)
      pattern = Nx.gather(atlas, Nx.stack([bg_ref, column], axis: 2))

      compose_pixels_atlas(
        pattern,
        bg_attr,
        x,
        mask,
        sx,
        sprite_refs,
        sattr,
        svalid,
        palette,
        master,
        color_mask,
        edge_mask,
        atlas
      )
    end

    defn compose_atlas_lit(
           attr,
           refs,
           fine_x,
           mask,
           sx,
           sprite_refs,
           sattr,
           svalid,
           palette,
           master,
           color_mask,
           edge_mask,
           atlas,
           emitter_lut
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      column = band(source_x, 7)
      pattern = Nx.gather(atlas, Nx.stack([bg_ref, column], axis: 2))

      {pixels, emission} =
        compose_pixel_plane_atlas_lit(
          pattern,
          bg_attr,
          x,
          mask,
          sx,
          sprite_refs,
          sattr,
          svalid,
          atlas,
          emitter_lut
        )

      finish_rgb_lit(
        pixels,
        emission,
        x,
        palette,
        master,
        color_mask,
        edge_mask
      )
    end

    defn compose_atlas_pixels(
           attr,
           refs,
           fine_x,
           mask,
           sx,
           sprite_refs,
           sattr,
           svalid,
           atlas
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      column = band(source_x, 7)
      pattern = Nx.gather(atlas, Nx.stack([bg_ref, column], axis: 2))

      compose_pixel_plane_atlas(
        pattern,
        bg_attr,
        x,
        mask,
        sx,
        sprite_refs,
        sattr,
        svalid,
        atlas
      )
    end

    defn compose_hybrid(
           lo,
           hi,
           attr,
           refs,
           bg_mode,
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
           edge_mask,
           atlas
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bit = 7 - band(source_x, 7)
      bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
      bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
      byte_pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      atlas_pattern = Nx.gather(atlas, Nx.stack([bg_ref, band(source_x, 7)], axis: 2))
      use_atlas = Nx.broadcast(bg_mode != 0, {@height, @width})
      pattern = Nx.select(use_atlas, atlas_pattern, byte_pattern)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)

      compose_pixels(
        pattern,
        bg_attr,
        x,
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
      )
    end

    defn compose_hybrid_lit(
           lo,
           hi,
           attr,
           refs,
           bg_mode,
           fine_x,
           mask,
           sx,
           stile,
           slo,
           shi,
           sattr,
           svalid,
           palette,
           master,
           color_mask,
           edge_mask,
           atlas,
           emitter_lut
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bit = 7 - band(source_x, 7)
      bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
      bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
      byte_pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      atlas_pattern = Nx.gather(atlas, Nx.stack([bg_ref, band(source_x, 7)], axis: 2))
      use_atlas = Nx.broadcast(bg_mode != 0, {@height, @width})
      pattern = Nx.select(use_atlas, atlas_pattern, byte_pattern)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)

      compose_pixels_lit(
        pattern,
        bg_attr,
        x,
        mask,
        sx,
        stile,
        slo,
        shi,
        sattr,
        svalid,
        palette,
        master,
        color_mask,
        edge_mask,
        emitter_lut
      )
    end

    defn compose_hybrid_pixels(
           lo,
           hi,
           attr,
           refs,
           bg_mode,
           fine_x,
           mask,
           sx,
           slo,
           shi,
           sattr,
           svalid,
           atlas
         ) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      source_x = x + Nx.as_type(fine_x, :s32)
      tile = Nx.quotient(source_x, 8)
      bit = 7 - band(source_x, 7)
      bg_lo = Nx.take_along_axis(lo, tile, axis: 1) |> Nx.as_type(:s32)
      bg_hi = Nx.take_along_axis(hi, tile, axis: 1) |> Nx.as_type(:s32)
      byte_pattern = bor(band(shr(bg_lo, bit), 1), band(shr(bg_hi, bit), 1) * 2)
      bg_ref = Nx.take_along_axis(refs, tile, axis: 1) |> Nx.as_type(:s32)
      atlas_pattern = Nx.gather(atlas, Nx.stack([bg_ref, band(source_x, 7)], axis: 2))
      use_atlas = Nx.broadcast(bg_mode != 0, {@height, @width})
      pattern = Nx.select(use_atlas, atlas_pattern, byte_pattern)
      bg_attr = Nx.take_along_axis(attr, tile, axis: 1) |> Nx.as_type(:s32)

      compose_pixel_plane(pattern, bg_attr, x, mask, sx, slo, shi, sattr, svalid)
    end

    defnp compose_pixels(
            pattern,
            bg_attr,
            x,
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
      pixels = compose_pixel_plane(pattern, bg_attr, x, mask, sx, slo, shi, sattr, svalid)
      finish_rgb(pixels, x, palette, master, color_mask, edge_mask)
    end

    defnp compose_pixels_lit(
            pattern,
            bg_attr,
            x,
            mask,
            sx,
            stile,
            slo,
            shi,
            sattr,
            svalid,
            palette,
            master,
            color_mask,
            edge_mask,
            emitter_lut
          ) do
      {pixels, emission} =
        compose_pixel_plane_lit(
          pattern,
          bg_attr,
          x,
          mask,
          sx,
          stile,
          slo,
          shi,
          sattr,
          svalid,
          emitter_lut
        )

      finish_rgb_lit(
        pixels,
        emission,
        x,
        palette,
        master,
        color_mask,
        edge_mask
      )
    end

    defnp compose_pixel_plane_lit(
            pattern,
            bg_attr,
            x,
            mask,
            sx,
            stile,
            slo,
            shi,
            sattr,
            svalid,
            emitter_lut
          ) do
      bg =
        Nx.select(
          pattern == 0 or band(mask, 8) == 0 or (x < 8 and band(mask, 2) == 0),
          0,
          bg_attr * 4 + pattern
        )

      sprite = Nx.broadcast(0, {@height, @width + 1})

      sprite =
        scatter_sprite_lit(sprite, 7, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 6, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 5, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 4, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 3, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 2, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 1, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      sprite =
        scatter_sprite_lit(sprite, 0, mask, sx, stile, slo, shi, sattr, svalid, emitter_lut)

      finish_pixel_plane_lit(bg, sprite)
    end

    defnp compose_pixel_plane(pattern, bg_attr, x, mask, sx, slo, shi, sattr, svalid) do
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

      finish_pixel_plane(bg, sprite)
    end

    defnp finish_pixel_plane(bg, sprite) do
      sprite = Nx.slice_along_axis(sprite, 0, @width, axis: 1)
      sprite_addr = band(sprite, 0x3F)
      sprite_front = band(sprite, 0x40) != 0
      visible = sprite_addr != 0

      Nx.select(visible and (bg == 0 or sprite_front), sprite_addr, bg) |> Nx.as_type(:u8)
    end

    defnp finish_pixel_plane_lit(bg, sprite) do
      sprite = Nx.slice_along_axis(sprite, 0, @width, axis: 1)
      sprite_addr = band(sprite, 0x3F)
      sprite_front = band(sprite, 0x40) != 0
      visible = sprite_addr != 0
      wins = visible and (bg == 0 or sprite_front)
      pixels = Nx.select(wins, sprite_addr, bg) |> Nx.as_type(:u8)
      emission = Nx.select(wins, band(shr(sprite, 8), 0xFFFF), 0) |> Nx.as_type(:u16)
      {pixels, emission}
    end

    defnp finish_rgb(pixels, x, palette, master, color_mask, edge_mask) do
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

    defnp finish_rgb_lit(
            pixels,
            emission,
            x,
            palette,
            master,
            color_mask,
            edge_mask
          ) do
      {pixels, rgb} = finish_rgb(pixels, x, palette, master, color_mask, edge_mask)

      # The winning sprite pixel already resolves through the NES palette here,
      # so retain its source hue in the emission field instead of asking the
      # game manifest to duplicate palette information. The packed LUT value
      # carries per-rule intensity and flicker depth; zero intensity removes all
      # non-emitting pixels from the compact field.
      colors = Nx.take(palette, pixels) |> band(color_mask)
      intensity = emission |> band(0xFF) |> Nx.as_type(:u8)
      flicker = emission |> shr(8) |> band(0xFF) |> Nx.as_type(:u8)
      flicker = Nx.select(intensity != 0, flicker, 0) |> Nx.as_type(:u8)
      colors = Nx.select(intensity != 0, colors, 0) |> Nx.as_type(:u8)
      emission = Nx.stack([colors, intensity, flicker], axis: 2)
      {pixels, rgb, emission}
    end

    defn resolve_composed_emission(pixels, palette, color_mask, provenance, emitter_lut) do
      provenance = Nx.as_type(provenance, :s32)
      tile = shr(provenance, 4)
      subpalette = band(shr(provenance, 2), 0x03)
      pattern = band(provenance, 0x03)
      emission = Nx.gather(emitter_lut, Nx.stack([tile, subpalette, pattern], axis: 2))
      intensity = emission |> band(0xFF) |> Nx.as_type(:u8)
      flicker = emission |> shr(8) |> band(0xFF) |> Nx.as_type(:u8)
      colors = Nx.take(palette, Nx.as_type(pixels, :s32)) |> band(color_mask)
      colors = Nx.select(intensity != 0, colors, 0) |> Nx.as_type(:u8)
      flicker = Nx.select(intensity != 0, flicker, 0) |> Nx.as_type(:u8)
      Nx.stack([colors, intensity, flicker], axis: 2)
    end

    defn compose_lighting(
           emission,
           master,
           kernel_horizontal,
           kernel_vertical,
           strength,
           edge_mask,
           frame_number,
           rgb
         ) do
      # Halos are a low-frequency field, so average to half resolution before
      # treating RGB as three examples in one convolution batch. Three
      # quarter-sized planes are cheaper than the former full-sized scalar
      # plane while retaining independent source hues.
      emission = Nx.as_type(emission, :f32)

      color_index =
        emission
        |> Nx.slice_along_axis(0, 1, axis: 2)
        |> Nx.squeeze(axes: [2])
        |> Nx.as_type(:s32)

      intensity = emission |> Nx.slice_along_axis(1, 1, axis: 2) |> Nx.squeeze(axes: [2])

      source_rgb =
        master
        |> Nx.take(color_index)
        |> Nx.as_type(:f32)
        |> Nx.multiply(Nx.new_axis(intensity / 255.0, 2))
        |> Nx.reshape({@lighting_height, @lighting_scale, @lighting_width, @lighting_scale, 3})
        |> Nx.mean(axes: [1, 3])

      flicker =
        emission
        |> Nx.slice_along_axis(2, 1, axis: 2)
        |> Nx.squeeze(axes: [2])
        |> Nx.reshape({@lighting_height, @lighting_scale, @lighting_width, @lighting_scale})
        |> Nx.reduce_max(axes: [1, 3])

      x = Nx.iota({@lighting_height, @lighting_width}, axis: 1, type: :f32) * @lighting_scale
      y = Nx.iota({@lighting_height, @lighting_width}, axis: 0, type: :f32) * @lighting_scale
      frame = Nx.as_type(frame_number, :f32)
      phase = x * 0.071 + y * 0.113

      organic =
        0.58 +
          Nx.sin(frame * 0.19 + phase) * 0.24 +
          Nx.sin(frame * 0.071 + phase * 1.7) * 0.12 +
          Nx.sin(frame * 0.37 + phase * 0.37) * 0.06

      amount = flicker / 255.0
      modulation = 1.0 - amount * (1.0 - Nx.clip(organic, 0.0, 1.0))

      emission =
        source_rgb
        |> Nx.multiply(Nx.new_axis(modulation, 2))
        |> Nx.transpose(axes: [2, 0, 1])
        |> Nx.new_axis(1)

      picture_x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      in_picture = picture_x >= edge_mask and picture_x < @width - edge_mask

      glow =
        emission
        |> Nx.conv(kernel_horizontal, padding: :same)
        |> Nx.conv(kernel_vertical, padding: :same)
        |> Nx.squeeze(axes: [1])
        |> Nx.transpose(axes: [1, 2, 0])
        |> Nx.new_axis(1)
        |> Nx.broadcast({@lighting_height, @lighting_scale, @lighting_width, 3})
        |> Nx.new_axis(3)
        |> Nx.broadcast({@lighting_height, @lighting_scale, @lighting_width, @lighting_scale, 3})
        |> Nx.reshape({@height, @width, 3})

      in_picture = in_picture |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})

      glow = Nx.select(in_picture, glow * strength, 0)

      Nx.as_type(rgb, :u16)
      |> Nx.add(Nx.as_type(glow, :u16))
      |> Nx.clip(0, 255)
      |> Nx.as_type(:u8)
    end

    defnp scatter_sprite_atlas(pixels, rank, mask, sx, sprite_refs, sattr, svalid, atlas) do
      rows = Nx.iota({@height, 8}, axis: 0, type: :s32)
      subpixel = Nx.iota({@height, 8}, axis: 1, type: :s32)
      x = Nx.new_axis(Nx.as_type(sx[[.., rank]], :s32), 1) + subpixel
      attr = Nx.new_axis(Nx.as_type(sattr[[.., rank]], :s32), 1)
      flip = Nx.broadcast(band(attr, 64) != 0, {@height, 8})
      source_col = Nx.select(flip, 7 - subpixel, subpixel)
      ref = Nx.new_axis(Nx.as_type(sprite_refs[[.., rank]], :s32), 1)
      ref = Nx.broadcast(ref, {@height, 8})
      pattern = Nx.gather(atlas, Nx.stack([ref, source_col], axis: 2))
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

    defnp scatter_sprite_atlas_lit(
            pixels,
            rank,
            mask,
            sx,
            sprite_refs,
            sattr,
            svalid,
            atlas,
            emitter_lut
          ) do
      rows = Nx.iota({@height, 8}, axis: 0, type: :s32)
      subpixel = Nx.iota({@height, 8}, axis: 1, type: :s32)
      x = Nx.new_axis(Nx.as_type(sx[[.., rank]], :s32), 1) + subpixel
      attr = Nx.new_axis(Nx.as_type(sattr[[.., rank]], :s32), 1)
      flip = Nx.broadcast(band(attr, 64) != 0, {@height, 8})
      source_col = Nx.select(flip, 7 - subpixel, subpixel)
      ref = Nx.new_axis(Nx.as_type(sprite_refs[[.., rank]], :s32), 1)
      ref = Nx.broadcast(ref, {@height, 8})
      pattern = Nx.gather(atlas, Nx.stack([ref, source_col], axis: 2))
      line_mask = Nx.as_type(mask, :s32)

      visible =
        Nx.new_axis(svalid[[.., rank]] != 0, 1) and pattern != 0 and x < @width and
          band(line_mask, 16) != 0 and
          (x >= 8 or band(line_mask, 4) != 0)

      columns = Nx.select(visible, x, @width)
      indices = Nx.stack([rows, columns], axis: 2) |> Nx.reshape({@height * 8, 2})
      front = Nx.select(band(attr, 32) == 0, 0x40, 0)
      subpalette = Nx.broadcast(band(attr, 3), {@height, 8})
      tile = Nx.quotient(ref, 8)
      emission = Nx.gather(emitter_lut, Nx.stack([tile, subpalette, pattern], axis: 2))
      values = 16 + subpalette * 4 + pattern + front + Nx.as_type(emission, :s32) * 256
      Nx.indexed_put(pixels, indices, Nx.reshape(values, {@height * 8}))
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

    defnp scatter_sprite_lit(
            pixels,
            rank,
            mask,
            sx,
            stile,
            slo,
            shi,
            sattr,
            svalid,
            emitter_lut
          ) do
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
      subpalette = Nx.broadcast(band(attr, 3), {@height, 8})
      tile = Nx.new_axis(Nx.as_type(stile[[.., rank]], :s32), 1)
      tile = Nx.broadcast(tile, {@height, 8})
      emission = Nx.gather(emitter_lut, Nx.stack([tile, subpalette, pattern], axis: 2))
      values = 16 + subpalette * 4 + pattern + front + Nx.as_type(emission, :s32) * 256
      Nx.indexed_put(pixels, indices, Nx.reshape(values, {@height * 8}))
    end

    defp pack_bytes(lines) do
      Enum.reduce(lines, {[], [], [], [], [], [], [], [], [], [], []}, fn
        {lo, hi, attr, fine_x, mask, sx, stile, slo, shi, sattr, svalid},
        {los, his, attrs, fine_xs, masks, sxs, stiles, slos, shis, sattrs, svalids} ->
          {
            [lo | los],
            [hi | his],
            [attr | attrs],
            [<<fine_x>> | fine_xs],
            [<<mask>> | masks],
            [sx | sxs],
            [stile | stiles],
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

    defp pack_atlas(lines) do
      Enum.reduce(lines, {[], [], [], [], [], [], [], []}, fn
        {_lo, _hi, attr, refs, _bg_mode, fine_x, mask, sx, sprite_refs, _shi, sattr, svalid},
        {attrs, all_refs, fine_xs, masks, sxs, all_sprite_refs, sattrs, svalids} ->
          {
            [attr | attrs],
            [refs | all_refs],
            [<<fine_x>> | fine_xs],
            [<<mask>> | masks],
            [sx | sxs],
            [sprite_refs | all_sprite_refs],
            [sattr | sattrs],
            [svalid | svalids]
          }
      end)
      |> Tuple.to_list()
      |> Enum.map(fn values -> values |> Enum.reverse() |> IO.iodata_to_binary() end)
      |> List.to_tuple()
    end

    defp pack_hybrid(lines) do
      Enum.reduce(lines, {[], [], [], [], [], [], [], [], [], [], [], [], []}, fn
        {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, stile, slo, shi, sattr, svalid},
        {los, his, attrs, all_refs, bg_modes, fine_xs, masks, sxs, stiles, slos, shis, sattrs,
         svalids} ->
          {
            [lo | los],
            [hi | his],
            [attr | attrs],
            [refs | all_refs],
            [<<bg_mode>> | bg_modes],
            [<<fine_x>> | fine_xs],
            [<<mask>> | masks],
            [sx | sxs],
            [stile | stiles],
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

    defp tensor(binary, shape), do: tensor(binary, shape, :u8)
    defp tensor(binary, shape, type), do: binary |> Nx.from_binary(type) |> Nx.reshape(shape)

    defp compiled(kind, args, output) do
      key =
        {@compiled_key, Beamicom.NES.Nx.compiler_options(), kind, output,
         Enum.map(args, &Nx.shape/1)}

      case :persistent_term.get(key, nil) do
        nil ->
          fun =
            case {kind, output} do
              {:bytes, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_bytes/14, args)

              {:atlas, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_atlas/13, args)

              {:hybrid, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_hybrid/17, args)

              {:bytes_lit, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_bytes_lit/16, args)

              {:atlas_lit, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_atlas_lit/14, args)

              {:hybrid_lit, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_hybrid_lit/19, args)

              {:lighting, :rgb} ->
                Beamicom.NES.Nx.compile(&compose_lighting/8, args)

              {:provenance, :emission} ->
                Beamicom.NES.Nx.compile(&resolve_composed_emission/5, args)

              {:bytes, :pixels} ->
                Beamicom.NES.Nx.compile(&compose_bytes_pixels/10, args)

              {:atlas, :pixels} ->
                Beamicom.NES.Nx.compile(&compose_atlas_pixels/9, args)

              {:hybrid, :pixels} ->
                Beamicom.NES.Nx.compile(&compose_hybrid_pixels/13, args)
            end

          :persistent_term.put(key, fun)
          fun

        fun ->
          fun
      end
    end

    defp atlas(key), do: :persistent_term.get(key)

    defp atlas_only?(lines), do: Enum.all?(lines, &(elem(&1, 4) == 1))

    defp decode_chr(chr) do
      for <<tile::binary-size(16) <- chr>>, row <- 0..7, into: <<>> do
        lo = :binary.at(tile, row)
        hi = :binary.at(tile, row + 8)

        for bit <- 7..0//-1, into: <<>> do
          <<Bitwise.band(Bitwise.bsr(hi, bit), 1) * 2 +
              Bitwise.band(Bitwise.bsr(lo, bit), 1)>>
        end
      end
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(bor(a, b), do: Nx.bitwise_or(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))
  end
end
