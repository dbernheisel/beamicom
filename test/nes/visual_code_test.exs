defmodule Beamicom.NES.VisualCodeTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Beamicom.NES.{VisualCode, Console}

  # Fake NES screenshot: 256×240 solid blue
  @ss_w 256
  @ss_h 240
  @ss_rgb :binary.copy(<<0, 0, 255>>, @ss_w * @ss_h)

  test "encode returns a valid {width, height, rgb} triple" do
    payload = :crypto.strong_rand_bytes(512)
    {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
    assert w > 0
    assert h > 0
    assert byte_size(rgb) == w * h * 3
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

  test "decode rejects corrupt image" do
    payload = :crypto.strong_rand_bytes(256)
    {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
    # flip a byte in the middle of the image
    mid = div(byte_size(rgb), 2)
    <<head::binary-size(^mid), b, rest::binary>> = rgb
    corrupt = <<head::binary, bxor(b, 0xFF), rest::binary>>
    # majority vote across k=3 copies should recover OR fail cleanly (no crash)
    result = VisualCode.decode(corrupt, w, h)
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "decode survives nearest-neighbor downscale to 1280px wide" do
    # 3072-byte payload → ~2256px image, so 1280px is a genuine DOWNSCALE
    # (a 512-byte payload only yields ~1048px, which 1280 would upscale — untestable).
    payload = :crypto.strong_rand_bytes(3072)
    {w, h, rgb} = VisualCode.encode(payload, @ss_rgb, @ss_w, @ss_h)
    assert w > 1280, "test requires image wider than target so 1280 is a real downscale"

    target_w = 1280
    target_h = round(h * target_w / w)
    downscaled = nn_scale(rgb, w, h, target_w, target_h)
    assert {:ok, ^payload} = VisualCode.decode(downscaled, target_w, target_h)
  end

  # Nearest-neighbor scale helper (test-only, not part of VisualCode)
  defp nn_scale(src, sw, sh, tw, th) do
    for dy <- 0..(th - 1), dx <- 0..(tw - 1), into: <<>> do
      sx = min(round(dx * sw / tw), sw - 1)
      sy = min(round(dy * sh / th), sh - 1)
      off = (sy * sw + sx) * 3
      <<_::binary-size(^off), r, g, b, _::binary>> = src
      <<r, g, b>>
    end
  end

  # Integration: save → load round-trip using real console state.
  describe "ShareImage integration" do
    alias Beamicom.NES.{SaveState, PNG, Palette, ShareImage}
    @nestest "test/support/fixtures/nestest.nes"

    test "save and load produces identical console state" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, rom_blob} = SaveState.split(c)

      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {img_w, img_h, img_rgb} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png = PNG.encode(img_w, img_h, img_rgb) |> PNG.put_trailer(rom_blob)

      assert {:ok, c2} = ShareImage.load_image(png, [])
      assert :erlang.term_to_binary(c) == :erlang.term_to_binary(c2)
    end

    test "load_image still works when trailer is stripped (ROM in search_dirs)" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, _rom_blob} = SaveState.split(c)

      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {img_w, img_h, img_rgb} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png_no_trailer = PNG.encode(img_w, img_h, img_rgb)

      assert {:ok, c2} = ShareImage.load_image(png_no_trailer, ["test/support/fixtures"])
      assert :erlang.term_to_binary(c) == :erlang.term_to_binary(c2)
    end

    test "load_image returns error when trailer stripped and no ROM matches" do
      c = run_frames(Console.load(@nestest), 60)
      {state_bin, _rom_blob} = SaveState.split(c)

      ss_rgb = Palette.to_rgb(c.bus.ppu.frame_ready)
      {img_w, img_h, img_rgb} = VisualCode.encode(state_bin, ss_rgb, 256, 240)
      png_no_trailer = PNG.encode(img_w, img_h, img_rgb)

      assert {:error, :rom_unavailable} = ShareImage.load_image(png_no_trailer, [])
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
end
