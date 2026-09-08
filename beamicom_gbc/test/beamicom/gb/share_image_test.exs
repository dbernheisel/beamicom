defmodule Beamicom.GB.ShareImageTest do
  use ExUnit.Case, async: true

  alias Beamicom.GB.{DiagnosticROM, Machine, PNG, ShareImage, System, VisualCode}

  test "self-contained CGB image restores and continues bit-exactly" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    png = ShareImage.to_png(machine, video.data)

    assert ShareImage.classify(png) == :gb
    assert {:ok, restored} = ShareImage.load_image(png)
    {expected_machine, expected_outputs} = System.run_slice(machine)
    {actual_machine, actual_outputs} = System.run_slice(restored)

    assert actual_outputs == expected_outputs
    assert :erlang.term_to_binary(actual_machine) == :erlang.term_to_binary(expected_machine)

    {width, height, rgb} = PNG.decode_rgb(png)
    assert {:ok, {_left, _top, 640, 576}} = VisualCode.screenshot_rect(width, height)
    assert byte_size(rgb) == width * height * 3
  end

  test "DMG share screenshot retains the green palette" do
    rom = DiagnosticROM.build()
    {:ok, machine} = Machine.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    png = ShareImage.to_png(machine, video.data)
    {width, height, rgb} = PNG.decode_rgb(png)
    {:ok, {left, top, 640, 576}} = VisualCode.screenshot_rect(width, height)

    native_rgb = PNG.to_rgb(video.data, :dmg_shade_index, :dmg_green)
    expected = binary_part(native_rgb, 0, 3)

    for y <- top..(top + 3), x <- left..(left + 3) do
      assert binary_part(rgb, (y * width + x) * 3, 3) == expected
    end

    assert {:ok, restored} = ShareImage.load_image(png)
    {_expected_machine, expected_outputs} = System.run_slice(machine)
    {_actual_machine, actual_outputs} = System.run_slice(restored)
    assert actual_outputs == expected_outputs
  end

  test "finds an identity-matched ROM when the exact-transfer trailer is stripped" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    png = ShareImage.to_png(machine, video.data)
    {:ok, trailer} = ShareImage.get_trailer(png)
    trailer_size = byte_size("BMIC\0GBSV") + 4 + byte_size(trailer)
    stripped = binary_part(png, 0, byte_size(png) - trailer_size)

    directory = temporary_directory()
    File.write!(Path.join(directory, "game.gbc"), rom)

    assert {:ok, restored} = ShareImage.load_image(stripped, [directory])
    assert restored.bus.cartridge.rom == rom
    assert {:error, :rom_unavailable} = ShareImage.load_image(stripped, [])
  end

  test "rejects malformed PNGs and truncated trailers" do
    assert {:error, :invalid_png} = ShareImage.load_image("not png")
    assert {:error, :corrupt_trailer} = ShareImage.get_trailer("pngBMIC\0GBSV" <> <<100::32, 1>>)
  end

  test "trailer framing is anchored after IEND and permits magic inside its blob" do
    png = PNG.encode(:binary.copy(<<0>>, 160 * 144))
    blob = <<"prefix", "BMIC\0GBSV", 42::32, "suffix">>
    framed = ShareImage.put_trailer(png, blob)

    assert {:ok, ^blob} = ShareImage.get_trailer(framed)
    assert {:error, :corrupt_trailer} = ShareImage.get_trailer(framed <> "extra")

    assert {:error, :corrupt_trailer} =
             ShareImage.get_trailer(binary_part(framed, 0, byte_size(framed) - 1))
  end

  test "GBC trailer keeps a corrupted visible marker classified as GBC" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    png = ShareImage.to_png(machine, video.data)
    # The first border cell is the first marker bit. Flip its sampled pixel in
    # the IDAT source by rebuilding the PNG while retaining the exact trailer.
    {width, height, rgb} = PNG.decode_rgb(png)
    offset = (width + 1) * 3
    <<head::binary-size(^offset), byte, rest::binary>> = rgb
    damaged_rgb = <<head::binary, 255 - byte, rest::binary>>
    {:ok, trailer} = ShareImage.get_trailer(png)
    damaged = PNG.encode_rgb(width, height, damaged_rgb) |> ShareImage.put_trailer(trailer)

    assert ShareImage.classify(damaged) == :gb
    assert {:error, :undecodable} = ShareImage.load_image(damaged)
  end

  defp temporary_directory do
    path =
      Path.join(
        Elixir.System.tmp_dir!(),
        "beamicom-gb-share-#{Elixir.System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
