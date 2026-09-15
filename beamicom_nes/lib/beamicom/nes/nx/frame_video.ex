if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameVideo do
    @moduledoc "Composed mapper-0 raw-state background and sprite frame defn."

    import Nx.Defn

    alias Beamicom.NES.Nx.{FrameBackground, FrameSprites}

    @doc "Return `{u8[240][256], sprite_overflow, sprite_zero_hit_scanline}`."
    defn render(vram, oam, atlas, ppu_writes, ppu_write_count, ppu_state) do
      {background, ctrl_lines, mask_lines} =
        FrameBackground.render_with_lines(vram, atlas, ppu_writes, ppu_write_count, ppu_state)

      {frame, _in_range, overflow, hit} =
        FrameSprites.render_lines(oam, atlas, background, ctrl_lines, mask_lines)

      {frame, overflow, hit}
    end
  end
end
