defmodule Beamicom.SNES.ShareImageTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{Machine, PNG, ShareImage, VisualCode}

  @tag :tmp_dir
  test "self-contained image restores and can find a stripped ROM", %{tmp_dir: tmp_dir} do
    rom = Beamicom.SNESTestROM.build(:lorom, program: <<0xEA, 0x80, 0xFD>>)
    {:ok, machine} = Machine.load(rom)
    frame = :binary.copy(<<16, 96, 224>>, 256 * 224)
    png = ShareImage.to_png(machine, frame)

    assert ShareImage.classify(png) == :snes
    assert {:ok, restored} = ShareImage.load_image(png)
    assert restored.cartridge.rom == rom

    {width, height, _rgb} = PNG.decode_rgb(png)
    assert {:ok, {_left, _top, 1024, 896}} = VisualCode.screenshot_rect(width, height)

    {:ok, trailer} = ShareImage.get_trailer(png)
    trailer_size = byte_size("BMIC\0SNSV") + 4 + byte_size(trailer)
    stripped = binary_part(png, 0, byte_size(png) - trailer_size)
    File.write!(Path.join(tmp_dir, "game.sfc"), rom)

    assert {:ok, restored} = ShareImage.load_image(stripped, [tmp_dir])
    assert restored.cartridge.rom == rom
    assert {:error, :rom_unavailable} = ShareImage.load_image(stripped, [])
  end

  test "rejects malformed PNGs and truncated trailers" do
    assert {:error, :invalid_png} = ShareImage.load_image("not png")

    assert {:error, :corrupt_trailer} =
             ShareImage.get_trailer("pngBMIC\0SNSV" <> <<100::32, 1>>)
  end
end
