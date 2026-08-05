defmodule BeamicomPhx.InputTest do
  use ExUnit.Case, async: true

  alias BeamicomPhx.Input

  describe "button_for/1" do
    test "maps arrow keys to the d-pad" do
      assert Input.button_for("ArrowUp") == :up
      assert Input.button_for("ArrowDown") == :down
      assert Input.button_for("ArrowLeft") == :left
      assert Input.button_for("ArrowRight") == :right
    end

    test "maps action/menu keys (case-insensitive for letters)" do
      assert Input.button_for("x") == :a
      assert Input.button_for("X") == :a
      assert Input.button_for("z") == :b
      assert Input.button_for("Z") == :b
      assert Input.button_for("Enter") == :start
      assert Input.button_for("Shift") == :select
    end

    test "returns nil for unmapped keys" do
      assert Input.button_for("q") == nil
      assert Input.button_for("F5") == nil
      assert Input.button_for(" ") == nil
    end
  end

  describe "apply_key/3" do
    test "keydown adds the button; returns the new held set and full button list" do
      assert {held, buttons} = Input.apply_key(MapSet.new(), :down, "ArrowRight")
      assert MapSet.equal?(held, MapSet.new([:right]))
      assert buttons == [:right]
    end

    test "accumulates multiple held buttons" do
      {held, _} = Input.apply_key(MapSet.new(), :down, "ArrowRight")
      {held, buttons} = Input.apply_key(held, :down, "x")
      assert MapSet.equal?(held, MapSet.new([:right, :a]))
      assert Enum.sort(buttons) == [:a, :right]
    end

    test "keyup removes the button" do
      held = MapSet.new([:right, :a])
      {held, buttons} = Input.apply_key(held, :up, "ArrowRight")
      assert MapSet.equal?(held, MapSet.new([:a]))
      assert buttons == [:a]
    end

    test "keydown of an already-held button is idempotent (key auto-repeat)" do
      held = MapSet.new([:a])
      {new_held, _} = Input.apply_key(held, :down, "x")
      assert MapSet.equal?(new_held, held)
    end

    test "ignores unmapped keys" do
      assert Input.apply_key(MapSet.new([:a]), :down, "q") == :ignore
    end
  end

  describe "button_from_name/1 and apply_button/3" do
    test "button_from_name maps known control names, nil otherwise" do
      assert Input.button_from_name("a") == :a
      assert Input.button_from_name("up") == :up
      assert Input.button_from_name("start") == :start
      assert Input.button_from_name("bogus") == nil
    end

    test "apply_button presses/releases like apply_key" do
      assert {held, [:a]} = Input.apply_button(MapSet.new(), :down, :a)
      assert MapSet.equal?(held, MapSet.new([:a]))
      assert {released, []} = Input.apply_button(held, :up, :a)
      assert MapSet.equal?(released, MapSet.new())
    end

    test "apply_button ignores unknown buttons" do
      assert Input.apply_button(MapSet.new(), :down, :turbo) == :ignore
    end
  end

  describe "press/2" do
    test "is a no-op (returns :ok) when no local Runtime is running" do
      refute Process.whereis(Beamicom.NES.Runtime)
      assert Input.press(1, [:a, :start]) == :ok
    end
  end
end
