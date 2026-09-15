defmodule Beamicom.NES.Nx.FrameVideoTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameVideo

  test "composes background, sprite priority, overflow, and sprite-zero status in one defn" do
    vram =
      Nx.tensor(List.duplicate(1, 960) ++ List.duplicate(0, 2048 - 960), type: :u8)

    oam = Nx.from_binary(<<9, 2, 0, 4>> <> :binary.copy(<<0xFF, 0, 0, 0>>, 63), :u8)
    atlas = Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8})
    atlas = Nx.put_slice(atlas, [1, 0, 0], Nx.broadcast(Nx.tensor(1, type: :u8), {1, 8, 8}))
    atlas = Nx.put_slice(atlas, [2, 0, 0], Nx.broadcast(Nx.tensor(2, type: :u8), {1, 8, 8}))
    writes = Nx.broadcast(Nx.tensor(0, type: :s32), {8, 3})
    state = Nx.tensor([0, 0x1E, 0, 0, 0, 1, 0], type: :s32)
    args = [vram, oam, atlas, writes, Nx.tensor(0, type: :s32), state]
    compiled = Beamicom.NES.Nx.compile(&FrameVideo.render/6, args)

    {frame, overflow, hit} = apply(compiled, args)

    assert Nx.shape(frame) == {240, 256}
    assert Nx.to_number(frame[10][3]) == 1
    assert Nx.to_number(frame[10][4]) == 18
    assert Nx.to_number(overflow) == 0
    assert Nx.to_number(hit) == 10
  end
end
