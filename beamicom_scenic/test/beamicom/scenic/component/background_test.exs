defmodule Beamicom.Scenic.Component.BackgroundTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Component.{Backdrop, Background, StatusBar}

  test "validates component dimensions and status data" do
    assert {:ok, {960, 800}} = Background.validate({960, 800})
    assert {:error, _message} = Background.validate({0, 800})

    data = %{size: {872, StatusBar.height()}, rom: nil}
    assert {:ok, ^data} = StatusBar.validate(data)
    assert {:error, _message} = StatusBar.validate(%{size: {-1, 48}})
  end

  test "ship and grid animation loops from elapsed monotonic time" do
    size = {960, 800}
    initial = Background.animation_frame(size, 0)

    assert initial.grid == Background.animation_frame(size, 1_400).grid
    assert Enum.at(initial.ships, 0) == Enum.at(Background.animation_frame(size, 10_800).ships, 0)
    assert initial != Background.animation_frame(size, 33)

    for %{position: {x, y}, scale: scale} <- initial.ships do
      assert is_float(x)
      assert is_float(y)
      assert scale > 0
    end
  end

  test "the static and animated landscape horizons align inside the frame" do
    {_width, inner_height} = size = {916, 756}
    [animated_horizon | _grid] = Background.animation_frame(size, 0).grid

    assert Backdrop.horizon(inner_height + 44) == 22 + animated_horizon
  end
end
