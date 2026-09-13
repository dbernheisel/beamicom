if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.NES.Nx.PPURenderer do
    @moduledoc """
    Adaptive frame-wide NES pixel compositor.

    Immutable CHR ROM is decoded into an EXLA-resident tile atlas at cartridge
    load. CHR RAM and mapper-sensitive cases automatically use byte or hybrid
    capture inside the same renderer.
    """

    import Nx.Defn

    @height 240
    @width 256
    @tiles 33
    @sprites 8
    @compiled_key {__MODULE__, :compiled}

    def prepare_chr(chr), do: prepare_chr_atlas(chr)

    def prepare_chr_atlas(<<>>), do: nil

    def prepare_chr_atlas(chr) do
      key = {__MODULE__, :chr_atlas, :crypto.hash(:sha256, chr)}

      case :persistent_term.get(key, nil) do
        nil ->
          atlas =
            chr |> decode_chr() |> Nx.from_binary(:u8) |> Nx.reshape({div(byte_size(chr), 2), 8})

          atlas = Nx.backend_copy(atlas, {EXLA.Backend, client: :host})
          :persistent_term.put(key, atlas)

        _atlas ->
          :ok
      end

      key
    end

    def render(lines, palette, grayscale, edge_mask, renderer_state)
        when length(lines) == @height do
      {kind, args} = render_args(lines, palette, grayscale, edge_mask, renderer_state)
      {pixels, rgb} = compiled(kind, args, :rgb) |> apply(args)
      {Nx.to_binary(pixels), Nx.to_binary(rgb)}
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
      cond do
        renderer_state == nil ->
          {lo, hi, attr, fine_x, mask, sx, slo, shi, sattr, svalid} = pack_bytes(lines)

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
             atlas(renderer_state)
           ]}

        true ->
          {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, slo, shi, sattr, svalid} =
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
             atlas(renderer_state)
           ]}
      end
    end

    defp render_args(lines, palette, grayscale, edge_mask, renderer_state) do
      common = [
        tensor(palette, {32}),
        tensor(Beamicom.NES.Palette.master_binary(), {64, 3}),
        Nx.tensor(if(grayscale, do: 0x30, else: 0x3F), type: :u8),
        Nx.tensor(edge_mask, type: :u8)
      ]

      cond do
        renderer_state == nil ->
          {lo, hi, attr, fine_x, mask, sx, slo, shi, sattr, svalid} = pack_bytes(lines)

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
             | common
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
             tensor(svalid, {@height, @sprites})
             | common
           ] ++ [atlas(renderer_state)]}

        true ->
          {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, slo, shi, sattr, svalid} =
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
             tensor(svalid, {@height, @sprites})
             | common
           ] ++ [atlas(renderer_state)]}
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

    defp pack_bytes(lines) do
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
      Enum.reduce(lines, {[], [], [], [], [], [], [], [], [], [], [], []}, fn
        {lo, hi, attr, refs, bg_mode, fine_x, mask, sx, slo, shi, sattr, svalid},
        {los, his, attrs, all_refs, bg_modes, fine_xs, masks, sxs, slos, shis, sattrs, svalids} ->
          {
            [lo | los],
            [hi | his],
            [attr | attrs],
            [refs | all_refs],
            [<<bg_mode>> | bg_modes],
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

    defp tensor(binary, shape), do: tensor(binary, shape, :u8)
    defp tensor(binary, shape, type), do: binary |> Nx.from_binary(type) |> Nx.reshape(shape)

    defp compiled(kind, args, output) do
      key = {@compiled_key, kind, output, Nx.shape(List.last(args))}

      case :persistent_term.get(key, nil) do
        nil ->
          fun =
            case {kind, output} do
              {:bytes, :rgb} ->
                EXLA.compile(&compose_bytes/14, Enum.map(args, &Nx.to_template/1), client: :host)

              {:atlas, :rgb} ->
                EXLA.compile(&compose_atlas/13, Enum.map(args, &Nx.to_template/1), client: :host)

              {:hybrid, :rgb} ->
                EXLA.compile(&compose_hybrid/17, Enum.map(args, &Nx.to_template/1), client: :host)

              {:bytes, :pixels} ->
                EXLA.compile(&compose_bytes_pixels/10, Enum.map(args, &Nx.to_template/1),
                  client: :host
                )

              {:atlas, :pixels} ->
                EXLA.compile(&compose_atlas_pixels/9, Enum.map(args, &Nx.to_template/1),
                  client: :host
                )

              {:hybrid, :pixels} ->
                EXLA.compile(&compose_hybrid_pixels/13, Enum.map(args, &Nx.to_template/1),
                  client: :host
                )
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
