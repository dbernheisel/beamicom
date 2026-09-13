defmodule Beamicom.NES.Nx.PPUAtlasRenderer do
  @moduledoc """
  CHR-atlas variant of `Beamicom.NES.Nx.PPURenderer`.

  It expands immutable CHR ROM to an EXLA-resident 8-bit tile atlas when the
  cartridge loads. The native PPU then records mapper-resolved atlas row indices
  instead of reading pattern bytes for background tiles.
  """

  alias Beamicom.NES.Nx.PPURenderer

  def prepare_chr(chr), do: PPURenderer.prepare_chr_atlas(chr)

  def render(lines, palette, grayscale, edge_mask, renderer_state),
    do: PPURenderer.render(lines, palette, grayscale, edge_mask, renderer_state)
end
