defmodule Beamicom.NES.VisualCodeTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{VisualCode, Console, SaveState, PNG, Palette, ShareImage}

  # Fake NES screenshot: 256×240 solid blue
  @ss_w 256
  @ss_h 240
  @ss_rgb :binary.copy(<<0, 0, 255>>, @ss_w * @ss_h)
  @nestest "test/support/fixtures/nestest.nes"

  describe "codec" do
    test "encode returns a valid {width, height, rgb} triple" do
      {w, h, rgb} = VisualCode.encode(:crypto.strong_rand_bytes(512), @ss_rgb, @ss_w, @ss_h)
      assert w > 0 and h > 0
      assert byte_size(rgb) == w * h * 3
    end

    test "screenshot dominates the frame (slim bezel)" do
      {w, h, _} = VisualCode.encode(:crypto.strong_rand_bytes(3072), @ss_rgb, @ss_w, @ss_h)
      assert 1024 * 960 / (w * h) > 0.85
    end

    test "encode/decode round-trips 512-byte payload" do
      payload = :crypto.strong_rand_bytes(512)
      {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
      assert {:ok, ^payload} = VisualCode.decode(rgb, w, h)
    end

    test "encode/decode round-trips 3072-byte payload" do
      payload = :crypto.strong_rand_bytes(3072)
      {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
      assert {:ok, ^payload} = VisualCode.decode(rgb, w, h)
    end

    test "decode rejects an image with a corrupted data dot" do
      payload = :crypto.strong_rand_bytes(256)
      {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
      # Flip the center pixel of the first border cell (0,0) — center (1,1) at @dot=2.
      off = (1 * w + 1) * 3
      <<head::binary-size(^off), r, rest::binary>> = rgb
      corrupt = <<head::binary, 255 - r, rest::binary>>
      assert {:error, :undecodable} = VisualCode.decode(corrupt, w, h)
    end

    test "decode rejects a foreign image" do
      {w, h, _} = VisualCode.encode(:crypto.strong_rand_bytes(64), @ss_rgb, @ss_w, @ss_h)
      blank = :binary.copy(<<0, 0, 0>>, w * h)
      assert {:error, _} = VisualCode.decode(blank, w, h)
    end
  end

  describe "ShareImage integration" do
    test "save and load produces identical console state" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, rom_blob} = SaveState.split(c)
      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {w, h, img} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png = PNG.encode(w, h, img) |> PNG.put_trailer(rom_blob)

      assert {:ok, c2} = ShareImage.load_image(png, [])
      assert same_state?(c, c2)
    end

    test "load works when the trailer is stripped (ROM found by CRC)" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, _} = SaveState.split(c)
      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {w, h, img} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png = PNG.encode(w, h, img)

      assert {:ok, c2} = ShareImage.load_image(png, ["test/support/fixtures"])
      assert same_state?(c, c2)
    end

    test "load returns :rom_unavailable when trailer stripped and no ROM matches" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, _} = SaveState.split(c)
      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {w, h, img} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png = PNG.encode(w, h, img)

      assert {:error, :rom_unavailable} = ShareImage.load_image(png, [])
    end

    test "round-trips through a PNG file on disk" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, rom_blob} = SaveState.split(c)
      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {w, h, img} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png = PNG.encode(w, h, img) |> PNG.put_trailer(rom_blob)

      path = Path.join(System.tmp_dir!(), "vc_#{System.unique_integer([:positive])}.png")
      File.write!(path, png)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, c2} = ShareImage.load_image(File.read!(path), [])
      assert same_state?(c, c2)
    end
  end

  # Step until a frame has rendered (and at least n steps have elapsed).
  defp run_frames(console, n) do
    Enum.reduce_while(1..10_000_000, {console, 0}, fn _, {c, steps} ->
      c = Console.step(c)

      if c.bus.ppu.frame_ready && steps + 1 >= n,
        do: {:halt, {c, steps + 1}},
        else: {:cont, {c, steps + 1}}
    end)
    |> elem(0)
  end

  # Loaded state drops the transient last frame, so compare with that field cleared.
  defp same_state?(c, c2) do
    :erlang.term_to_binary(put_in(c.bus.ppu.frame_ready, nil)) == :erlang.term_to_binary(c2)
  end
end
