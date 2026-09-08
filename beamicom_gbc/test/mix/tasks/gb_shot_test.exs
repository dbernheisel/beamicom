defmodule Mix.Tasks.Gb.ShotTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.{DiagnosticROM, PNG}

  test "writes a deterministic PNG from an executed ROM" do
    root = Path.join(System.tmp_dir!(), "beamicom-gb-shot-#{System.unique_integer([:positive])}")
    rom = Path.join(root, "diagnostic.gb")
    output = Path.join(root, "captures/diagnostic.png")
    File.mkdir_p!(root)
    File.write!(rom, DiagnosticROM.build())

    on_exit(fn -> File.rm_rf(root) end)
    Mix.Task.reenable("gb.shot")
    Mix.Tasks.Gb.Shot.run([rom, output, "2", "grayscale"])

    assert File.regular?(output)
    assert {160, 144, rgb} = output |> File.read!() |> PNG.decode()
    assert byte_size(rgb) == 160 * 144 * 3
    assert length(Enum.uniq(for <<pixel::binary-size(3) <- rgb>>, do: pixel)) == 4
    assert :erlang.crc32(rgb) == 2_222_071_697
  end

  test "writes an executed CGB ROM's native RGB24 frame" do
    root = Path.join(System.tmp_dir!(), "beamicom-cgb-shot-#{System.unique_integer([:positive])}")
    rom = Path.join(root, "diagnostic.gbc")
    output = Path.join(root, "captures/diagnostic-cgb.png")
    File.mkdir_p!(root)
    File.write!(rom, DiagnosticROM.build_cgb())

    on_exit(fn -> File.rm_rf(root) end)
    Mix.Task.reenable("gb.shot")
    Mix.Tasks.Gb.Shot.run([rom, output])

    assert File.regular?(output)
    assert {160, 144, rgb} = output |> File.read!() |> PNG.decode()
    assert length(Enum.uniq(for <<pixel::binary-size(3) <- rgb>>, do: pixel)) == 26
    assert :erlang.crc32(rgb) == 642_352_328
  end

  test "reports invalid frame and palette arguments" do
    Mix.Task.reenable("gb.shot")

    assert_raise Mix.Error, ~r/frames must be a positive integer/, fn ->
      Mix.Tasks.Gb.Shot.run(["unused.gb", "unused.png", "0"])
    end

    Mix.Task.reenable("gb.shot")

    assert_raise Mix.Error, ~r/unsupported palette/, fn ->
      Mix.Tasks.Gb.Shot.run(["unused.gb", "unused.png", "1", "sepia"])
    end
  end
end
