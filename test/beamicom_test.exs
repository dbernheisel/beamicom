defmodule BeamicomTest do
  use ExUnit.Case
  doctest Beamicom

  test "greets the world" do
    assert Beamicom.hello() == :world
  end
end
