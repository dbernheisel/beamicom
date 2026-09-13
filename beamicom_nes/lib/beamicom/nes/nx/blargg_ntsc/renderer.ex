if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.NES.Nx.BlarggNTSC.Renderer do
    @moduledoc """
    Runtime-selectable NES PPU renderer with Blargg NTSC presentation.

    This composes the native palette-address plane with the resident CHR atlas and
    then applies `Beamicom.NES.Nx.BlarggNTSC`. The logical NES plane remains
    256x240 while the shared RGB presentation is 602x240.
    """

    alias Beamicom.NES.Nx.{BlarggNTSC, PPURenderer}

    @width 602
    @height 240

    def output_dimensions, do: {@width, @height}
    def output_dimensions(_options_or_state), do: output_dimensions()

    # The filter emits one 602-sample row for each of the NES's 240 scanlines.
    # Doubling rows gives those samples the intended square-pixel presentation.
    def pixel_scale, do: {1, 2}
    def pixel_scale(_options_or_state), do: pixel_scale()

    def prepare_chr(chr, options) do
      %{atlas: PPURenderer.prepare_chr_atlas(chr), ntsc: BlarggNTSC.prepare(options)}
    end

    def atlas_state(state), do: state.atlas

    def render(lines, palette, grayscale, edge_mask, state),
      do: render(lines, palette, grayscale, edge_mask, state, 0)

    def render(lines, palette, _grayscale, edge_mask, state, frame_number) do
      {pixels, masks} = PPURenderer.render_pixels_and_masks_tensor(lines, state.atlas)

      rgb =
        BlarggNTSC.filter_tensor(pixels, palette, masks, frame_number, edge_mask, state.ntsc)

      {Nx.to_binary(pixels), Nx.to_binary(rgb)}
    end
  end
end
