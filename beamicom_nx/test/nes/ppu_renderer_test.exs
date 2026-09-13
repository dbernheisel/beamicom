defmodule BeamicomNx.NES.PPURendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.PPU

  defp chr do
    tile1 = :binary.copy(<<0xAA>>, 8) <> :binary.copy(<<0x55>>, 8)
    tile2 = :binary.copy(<<0xF0>>, 8) <> :binary.copy(<<0x0F>>, 8)
    <<0::128>> <> tile1 <> tile2 <> <<0::size((8192 - 48) * 8)>>
  end

  defp scene(renderer) do
    # Repeating nontrivial background plus overlapping front/behind sprites makes
    # the comparison cover bit extraction, attributes, clipping and OAM priority.
    tiles = for i <- 0..959, into: <<>>, do: <<1 + rem(i, 2)>>
    vram = tiles <> <<0::size((0x800 - byte_size(tiles)) * 8)>>
    sprites = <<30, 2, 0x00, 40, 30, 1, 0x21, 44, 70, 2, 0x20, 4>>
    oam = sprites <> :binary.copy(<<0xFF, 0, 0, 0>>, 61)

    %{PPU.new(chr(), :horizontal) | mask: 0x1E, vram: vram, oam: oam}
    |> PPU.set_renderer(renderer)
    |> PPU.run(89_342 * 3)
  end

  test "frame-wide Nx composition is pixel-exact with native composition" do
    native = scene(:native)
    nx = scene(:nx)

    assert nx.frame_ready.pixels == native.frame_ready.pixels
    assert nx.status == native.status
    assert byte_size(nx.frame_ready.pixels) == 256 * 240
  end
end
