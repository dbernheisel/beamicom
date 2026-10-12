defmodule Beamicom.GBA.ShareImageTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{DiagnosticROM, Machine, PNG, ShareImage, System}

  test "self-contained PNG restores and continues exactly" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    png = ShareImage.to_png(machine, video.data)
    frame = video.data

    assert ShareImage.classify(png) == :gba
    assert {240, 160, ^frame} = PNG.decode_rgb(png)
    assert {:ok, restored} = ShareImage.load_image(png)

    {expected_machine, expected_outputs} = System.run_slice(machine)
    {actual_machine, actual_outputs} = System.run_slice(restored)

    assert actual_outputs == expected_outputs
    assert actual_machine == expected_machine
  end

  test "trailer framing is anchored after IEND and rejects truncation" do
    png = PNG.encode(:binary.copy(<<0>>, 240 * 160 * 3))
    framed = ShareImage.put_trailer(png, "state", "rom")

    assert {:ok, {"state", "rom"}} = ShareImage.get_trailer(framed)
    assert ShareImage.classify(framed) == :gba
    assert ShareImage.classify(png) == :not_gba
    assert {:error, :corrupt_trailer} = ShareImage.get_trailer(framed <> "extra")

    truncated = binary_part(framed, 0, byte_size(framed) - 1)
    assert {:error, :corrupt_trailer} = ShareImage.get_trailer(truncated)
  end

  test "rejects malformed and wrong-sized PNG previews" do
    assert {:error, :invalid_png} = ShareImage.load_image("not png")

    wrong_size = PNG.encode_rgb(1, 1, <<0, 0, 0>>) |> ShareImage.put_trailer("state", "rom")
    assert {:error, :invalid_dimensions} = ShareImage.load_image(wrong_size)
  end
end
