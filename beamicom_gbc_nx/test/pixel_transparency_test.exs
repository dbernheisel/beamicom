defmodule Beamicom.GB.Nx.PixelTransparencyTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.Nx.PixelTransparency

  test "bright LCD cells reveal the backing while dark cells remain dark" do
    source = Nx.tensor([[[0, 0, 0], [255, 255, 255]]], type: :u8)

    pixels =
      source
      |> PixelTransparency.filter_tensor({2, 1}, shadow_enable: 0.0)
      |> Nx.to_flat_list()
      |> Enum.chunk_every(3)

    [dark, bright] = pixels
    assert Enum.max(dark) <= 1
    assert Enum.all?(bright, &(&1 < 255))
    assert Enum.sum(bright) > Enum.sum(dark)
    assert Enum.uniq(bright) |> length() > 1
  end

  test "filter is deterministic and accepts documented parameter overrides" do
    source = Nx.tensor([[[240, 245, 250], [40, 80, 120]]], type: :u8)
    options = [base_alpha: 0.4, palette: 1.0, shadow_blur: 0.0, saturation: 0.8]

    first = PixelTransparency.filter_tensor(source, {4, 2}, options) |> Nx.to_binary()
    second = PixelTransparency.filter_tensor(source, {4, 2}, options) |> Nx.to_binary()

    assert first == second
    assert byte_size(first) == 4 * 2 * 3
  end
end
