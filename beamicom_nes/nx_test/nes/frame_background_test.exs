defmodule Beamicom.NES.Nx.FrameBackgroundTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameBackground

  test "renders a 256-wide tile-atlas gather as palette RAM addresses" do
    vram =
      Nx.tensor(List.duplicate(1, 960) ++ List.duplicate(0, 2048 - 960), type: :u8)

    atlas = Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8})
    atlas = Nx.put_slice(atlas, [1, 0, 0], Nx.broadcast(Nx.tensor(2, type: :u8), {1, 8, 8}))
    writes = Nx.broadcast(Nx.tensor(0, type: :s32), {8, 3})
    state = Nx.tensor([0, 0x0A, 0, 0, 0, 1, 0], type: :s32)

    frame = FrameBackground.render(vram, atlas, writes, Nx.tensor(0, type: :s32), state)

    assert Nx.shape(frame) == {240, 256}
    assert Nx.type(frame) == {:u, 8}
    assert Enum.uniq(Nx.to_flat_list(frame)) == [2]
  end

  test "replays scroll writes at scanline granularity" do
    vram = Nx.broadcast(Nx.tensor(0, type: :u8), {2048})
    vram = Nx.put_slice(vram, [0], Nx.tensor([1, 2], type: :u8))
    atlas = Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8})
    atlas = Nx.put_slice(atlas, [1, 0, 0], Nx.broadcast(Nx.tensor(1, type: :u8), {1, 8, 8}))
    atlas = Nx.put_slice(atlas, [2, 0, 0], Nx.broadcast(Nx.tensor(2, type: :u8), {1, 8, 8}))
    writes = Nx.tensor([[0, 0x2005, 8]] ++ List.duplicate([0, 0, 0], 7), type: :s32)
    state = Nx.tensor([0, 0x0A, 0, 0, 0, 1, 0], type: :s32)

    frame = FrameBackground.render(vram, atlas, writes, Nx.tensor(1, type: :s32), state)

    assert Nx.to_number(frame[0][0]) == 2
  end

  test "honors background enable and left-edge mask bits" do
    vram =
      Nx.tensor(List.duplicate(1, 960) ++ List.duplicate(0, 2048 - 960), type: :u8)

    atlas = Nx.broadcast(Nx.tensor(3, type: :u8), {512, 8, 8})
    writes = Nx.broadcast(Nx.tensor(0, type: :s32), {8, 3})

    disabled = Nx.tensor([0, 0, 0, 0, 0, 1, 0], type: :s32)
    clipped = Nx.tensor([0, 0x08, 0, 0, 0, 1, 0], type: :s32)

    disabled_frame = FrameBackground.render(vram, atlas, writes, Nx.tensor(0), disabled)
    assert Nx.to_number(disabled_frame[0][0]) == 0

    frame = FrameBackground.render(vram, atlas, writes, Nx.tensor(0), clipped)
    assert Nx.to_flat_list(frame[0][0..7//1]) == List.duplicate(0, 8)
    assert Nx.to_number(frame[0][8]) == 3
  end
end
