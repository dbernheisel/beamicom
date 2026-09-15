defmodule Beamicom.NES.Nx.FrameSpritesTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameSprites

  test "cumulative rank enforces eight sprites and raises overflow" do
    sprites = for x <- 0..8, into: <<>>, do: <<9, 1, 0, x * 8>>
    oam = Nx.from_binary(sprites <> :binary.copy(<<0xFF, 0, 0, 0>>, 55), :u8)
    atlas = solid_atlas(1, 1)
    background = Nx.broadcast(Nx.tensor(0, type: :u8), {240, 256})

    {_frame, mask, overflow, _hit} = render(oam, atlas, background, Nx.tensor(0), Nx.tensor(0x1E))

    assert Enum.sum(Nx.to_flat_list(mask[10])) == 9
    assert Nx.to_number(overflow) == 1
  end

  test "sprite priority overlays palette addresses and reports sprite-zero hit" do
    oam = Nx.from_binary(<<9, 1, 0, 4>> <> :binary.copy(<<0xFF, 0, 0, 0>>, 63), :u8)
    atlas = solid_atlas(1, 2)
    background = Nx.broadcast(Nx.tensor(1, type: :u8), {240, 256})

    {front, _mask, _overflow, hit} =
      render(oam, atlas, background, Nx.tensor(0), Nx.tensor(0x1E))

    assert Nx.to_number(front[10][4]) == 18
    assert Nx.to_number(hit) == 10

    behind_oam =
      Nx.from_binary(<<9, 1, 0x20, 4>> <> :binary.copy(<<0xFF, 0, 0, 0>>, 63), :u8)

    {behind, _mask, _overflow, behind_hit} =
      render(behind_oam, atlas, background, Nx.tensor(0), Nx.tensor(0x1E))

    assert Nx.to_number(behind[10][4]) == 1
    assert Nx.to_number(behind_hit) == 10
  end

  defp solid_atlas(tile, slot) do
    atlas = Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8})

    Nx.put_slice(
      atlas,
      [tile, 0, 0],
      Nx.broadcast(Nx.tensor(slot, type: :u8), {1, 8, 8})
    )
  end

  defp render(oam, atlas, background, ctrl, mask) do
    args = [oam, atlas, background, ctrl, mask]
    compiled = Beamicom.NES.Nx.compile(&FrameSprites.render/5, args)
    apply(compiled, args)
  end
end
