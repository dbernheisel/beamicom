if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameBackground do
    @moduledoc "Mapper-0 frame-parallel background renderer for the raw-state AOT experiment."

    import Nx.Defn

    @height 240
    @width 256

    @doc """
    Render native palette-RAM addresses from VRAM and a decoded CHR atlas.

    `state` is `{ctrl, mask, scroll_x, scroll_y, nametable, mirroring, scroll_latch}`;
    mirroring is 0 for horizontal and 1 for vertical. Register-log rows are
    `{CPU cycle, PPU register address, value}` and take effect at scanline
    granularity.
    """
    defn render(vram, atlas, writes, valid_count, state) do
      {frame, _ctrls, _masks} = render_with_lines(vram, atlas, writes, valid_count, state)
      frame
    end

    @doc false
    defn render_with_lines(vram, atlas, writes, valid_count, state) do
      lines = Nx.iota({@height}, type: :s32)
      ctrls = Nx.broadcast(state[0], {@height})
      masks = Nx.broadcast(state[1], {@height})
      scroll_x = Nx.broadcast(state[2], {@height})
      scroll_y = Nx.broadcast(state[3], {@height})
      nametables = Nx.broadcast(state[4], {@height})
      capacity = Nx.axis_size(writes, 0)

      {ctrls, masks, scroll_x, scroll_y, nametables, _latch} =
        while {ctrls, masks, scroll_x, scroll_y, nametables, latch = state[6]},
              index <- 0..(capacity - 1),
              unroll: 8 do
          cycle = writes[index][0]
          address = 0x2000 + band(writes[index][1], 7)
          value = writes[index][2]
          valid = index < valid_count
          scanline = Nx.clip(Nx.quotient(cycle * 3, 341), 0, @height)
          applies = valid and lines >= scanline
          ctrl_write = applies and address == 0x2000
          mask_write = applies and address == 0x2001
          scroll_write = valid and address == 0x2005
          first_scroll = scroll_write and latch == 0
          second_scroll = scroll_write and latch != 0

          {
            Nx.select(ctrl_write, value, ctrls),
            Nx.select(mask_write, value, masks),
            Nx.select(first_scroll and lines >= scanline, value, scroll_x),
            Nx.select(second_scroll and lines >= scanline, value, scroll_y),
            Nx.select(ctrl_write, band(value, 3), nametables),
            Nx.select(scroll_write, 1 - latch, latch)
          }
        end

      x = Nx.iota({1, @width}, axis: 1, type: :s32)
      y = Nx.iota({@height, 1}, axis: 0, type: :s32)
      scroll_x = Nx.reshape(scroll_x, {@height, 1})
      scroll_y = Nx.reshape(scroll_y, {@height, 1})
      nametables = Nx.reshape(nametables, {@height, 1})
      ctrls = Nx.reshape(ctrls, {@height, 1})
      masks = Nx.reshape(masks, {@height, 1})
      world_x = x + scroll_x
      world_y = y + scroll_y
      local_x = Nx.remainder(world_x, 256)
      local_y = Nx.remainder(world_y, 240)
      logical_x = Nx.remainder(band(nametables, 1) + Nx.quotient(world_x, 256), 2)
      logical_y = Nx.remainder(shr(nametables, 1) + Nx.quotient(world_y, 240), 2)
      logical = logical_x + logical_y * 2
      horizontal = shr(logical, 1)
      vertical = band(logical, 1)
      physical = Nx.select(state[5] == 0, horizontal, vertical)
      tile_x = Nx.quotient(local_x, 8)
      tile_y = Nx.quotient(local_y, 8)
      name_index = physical * 1024 + tile_y * 32 + tile_x
      tiles = Nx.take(Nx.reshape(vram, {2048}), name_index)
      pattern_table = Nx.select(band(ctrls, 0x10) != 0, 256, 0)

      atlas_index =
        (tiles + pattern_table) * 64 + Nx.remainder(local_y, 8) * 8 + Nx.remainder(local_x, 8)

      slots = Nx.take(Nx.reshape(atlas, {512 * 64}), atlas_index)

      attribute_index =
        physical * 1024 + 960 + Nx.quotient(tile_y, 4) * 8 + Nx.quotient(tile_x, 4)

      attributes = Nx.take(Nx.reshape(vram, {2048}), attribute_index)
      shift = band(tile_y, 2) * 2 + band(tile_x, 2)
      group = band(shr(attributes, shift), 3)
      palette_address = Nx.select(slots == 0, 0, group * 4 + slots)
      enabled = band(masks, 0x08) != 0
      left_visible = band(masks, 0x02) != 0 or x >= 8

      frame = Nx.select(enabled and left_visible, palette_address, 0) |> Nx.as_type(:u8)
      {frame, Nx.reshape(ctrls, {@height}), Nx.reshape(masks, {@height})}
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))
  end
end
