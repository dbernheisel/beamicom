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

  test "resolves supported systems and dynamic renderer geometry" do
    assert {:ok, %{id: :nes, runtime: :nes}} = BeamicomV4L2.Core.resolve("GAME.NES")
    assert {:ok, %{id: :gbc, runtime: :host}} = BeamicomV4L2.Core.resolve("game.gb")
    assert {:ok, %{id: :gbc, runtime: :host}} = BeamicomV4L2.Core.resolve("game.GBC")

    assert {:error, {:unsupported_media_extension, ".zip"}} =
             BeamicomV4L2.Core.resolve("game.zip")

    args =
      BeamicomV4L2.Player.renderer_args("/dev/fb0", 60, 3, %{width: 160, height: 144})

    assert "160x144" in args
    assert "scale=480:432:flags=neighbor" in args
  end

  @tag :tmp_dir
  test "rejects malformed media before opening framebuffer or V4L2 devices", %{tmp_dir: dir} do
    rom = Path.join(dir, "bad.gbc")
    File.write!(rom, "bad")

    assert {:error, {:rom_too_small, 0x150, 3}} =
             BeamicomV4L2.Player.start_link(
               rom: rom,
               framebuffer: "/definitely/missing/fb",
               output: "/definitely/missing/video",
               audio: false,
               name: nil
             )
  end
end
