defmodule BeamicomV4L2Test do
  use ExUnit.Case, async: true

  setup do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    :ok
  end

  test "rejects invalid frame rates before opening devices" do
    assert {:error, {:invalid_option, :fps}} = BeamicomV4L2.Stream.start_link(fps: 0)
    assert {:error, {:invalid_option, :fps}} = BeamicomV4L2.Stream.start_link(fps: 1_001)
  end

  test "reports a missing framebuffer without crashing the VM" do
    assert {:error, reason} =
             BeamicomV4L2.Stream.start_link(
               framebuffer: "/definitely/missing/fb",
               output: "/dev/video0"
             )

    assert is_binary(reason)
    assert reason =~ "/definitely/missing/fb"
  end

  test "maps keyboard controls to NES buttons" do
    assert BeamicomV4L2.Player.button_for("ArrowUp") == :up
    assert BeamicomV4L2.Player.button_for("X") == :a
    assert BeamicomV4L2.Player.button_for(:key_z) == :b
    assert BeamicomV4L2.Player.button_for("unmapped") == nil
  end
end
