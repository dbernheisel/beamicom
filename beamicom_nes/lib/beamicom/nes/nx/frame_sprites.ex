if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameSprites do
    @moduledoc "Frame-parallel NES sprite evaluation, limiting, and priority overlay."

    import Nx.Defn

    @height 240
    @width 256
    @sprites 64

    @doc "Return `{frame, in_range_mask, overflow, sprite_zero_hit_scanline}`."
    defn render(oam, atlas, background, ctrl, mask) do
      render_lines(
        oam,
        atlas,
        background,
        Nx.broadcast(ctrl, {@height}),
        Nx.broadcast(mask, {@height})
      )
    end

    @doc false
    defn render_lines(oam, atlas, background, ctrl_lines, mask_lines) do
      oam = Nx.reshape(oam, {@sprites, 4})
      sprite_y = Nx.take(oam, Nx.tensor(0), axis: 1) |> Nx.as_type(:s32)
      tile = Nx.take(oam, Nx.tensor(1), axis: 1) |> Nx.as_type(:s32)
      attributes = Nx.take(oam, Nx.tensor(2), axis: 1) |> Nx.as_type(:s32)
      sprite_x = Nx.take(oam, Nx.tensor(3), axis: 1) |> Nx.as_type(:s32)
      height = Nx.select(band(ctrl_lines, 0x20) != 0, 16, 8) |> Nx.reshape({@height, 1})
      scanline = Nx.iota({@height, 1}, axis: 0, type: :s32)

      in_range =
        scanline >= Nx.reshape(sprite_y + 1, {1, @sprites}) and
          scanline < Nx.reshape(sprite_y + 1, {1, @sprites}) + height

      ranks = Nx.cumulative_sum(Nx.as_type(in_range, :u8), axis: 1)
      selected = in_range and ranks <= 8
      overflow = Nx.any(in_range and ranks > 8) |> Nx.as_type(:u8)

      screen_x = Nx.iota({1, @width, 1}, axis: 1, type: :s32)
      screen_y = Nx.iota({@height, 1, 1}, axis: 0, type: :s32)
      sprite_y = Nx.reshape(sprite_y, {1, 1, @sprites})
      sprite_x = Nx.reshape(sprite_x, {1, 1, @sprites})
      tile = Nx.reshape(tile, {1, 1, @sprites})
      attributes = Nx.reshape(attributes, {1, 1, @sprites})
      selected = Nx.reshape(selected, {@height, 1, @sprites})
      height = Nx.reshape(height, {@height, 1, 1})
      ctrl_lines = Nx.reshape(ctrl_lines, {@height, 1, 1})
      mask_lines = Nx.reshape(mask_lines, {@height, 1})
      fine_x = screen_x - sprite_x
      fine_y = screen_y - (sprite_y + 1)
      flip_x = Nx.broadcast(band(attributes, 0x40) != 0, {@height, @width, @sprites})
      flip_y = Nx.broadcast(band(attributes, 0x80) != 0, {@height, @width, @sprites})
      fine_x = Nx.select(flip_x, 7 - fine_x, fine_x)
      fine_y = Nx.select(flip_y, height - 1 - fine_y, fine_y)
      safe_x = Nx.clip(fine_x, 0, 7)
      safe_y = fine_y |> Nx.max(0) |> Nx.min(height - 1)
      eight_by_sixteen = height == 16
      atlas_tile_8 = tile + Nx.select(band(ctrl_lines, 0x08) != 0, 256, 0)
      atlas_tile_16 = band(tile, 1) * 256 + band(tile, 0xFE) + Nx.quotient(safe_y, 8)

      atlas_tile =
        Nx.select(
          Nx.broadcast(eight_by_sixteen, {@height, @width, @sprites}),
          atlas_tile_16,
          atlas_tile_8 + safe_x * 0
        )

      atlas_index = atlas_tile * 64 + Nx.remainder(safe_y, 8) * 8 + safe_x
      slots = Nx.take(Nx.reshape(atlas, {512 * 64}), atlas_index)
      horizontally_in_range = fine_x >= 0 and fine_x < 8
      visible = selected and horizontally_in_range and slots != 0
      winner = visible and Nx.cumulative_sum(Nx.as_type(visible, :u8), axis: 2) == 1
      sprite_palette = 16 + band(attributes, 3) * 4 + slots
      winning_palette = Nx.sum(Nx.select(winner, sprite_palette, 0), axes: [2])
      winning_behind = Nx.any(winner and band(attributes, 0x20) != 0, axes: [2])
      has_sprite = Nx.any(winner, axes: [2])
      sprite_enabled = band(mask_lines, 0x10) != 0

      sprite_left_visible =
        band(mask_lines, 0x04) != 0 or Nx.reshape(screen_x, {1, @width}) >= 8

      has_sprite = has_sprite and sprite_enabled and sprite_left_visible
      foreground = background == 0 or not winning_behind
      frame = Nx.select(has_sprite and foreground, winning_palette, background) |> Nx.as_type(:u8)

      sprite_zero = winner and Nx.iota({1, 1, @sprites}, axis: 2, type: :s32) == 0
      zero_pixel = Nx.any(sprite_zero, axes: [2])
      background_enabled = band(mask_lines, 0x08) != 0

      background_left_visible =
        band(mask_lines, 0x02) != 0 or Nx.reshape(screen_x, {1, @width}) >= 8

      hit_pixel =
        zero_pixel and background != 0 and sprite_enabled and background_enabled and
          sprite_left_visible and background_left_visible and
          Nx.reshape(screen_x, {1, @width}) < 255

      hit_lines = Nx.any(hit_pixel, axes: [1])
      hit = Nx.reduce_min(Nx.select(hit_lines, Nx.iota({@height}, type: :s32), @height))
      hit = Nx.select(hit == @height, -1, hit)

      {frame, Nx.as_type(in_range, :u8), overflow, hit}
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
  end
end
