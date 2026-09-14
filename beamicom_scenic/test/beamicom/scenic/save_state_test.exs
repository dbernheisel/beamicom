defmodule Beamicom.Scenic.SaveStateTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.SaveState

  test "derives stable lowercase ROM hashes and a shared-folder quick slot" do
    prg = <<1, 2, 3>>
    chr = <<4, 5>>
    nes = %{bus: %{prg: prg, ppu: %{chr: chr}}}
    gbc = %{bus: %{cartridge: %{rom: prg <> chr}}}

    expected = :crypto.hash(:sha256, prg <> chr) |> Base.encode16(case: :lower)

    assert SaveState.rom_hash(:nes, nes) == expected
    assert SaveState.rom_hash(:gbc, gbc) == expected
    assert SaveState.quick_path("/tmp/states", expected) == "/tmp/states/#{expected}.png"
  end

  test "lists only states associated with the requested ROM hash" do
    folder =
      Path.join(System.tmp_dir!(), "beamicom-state-list-#{System.unique_integer([:positive])}")

    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf(folder) end)

    hash = String.duplicate("a", 64)
    other_hash = String.duplicate("b", 64)
    quick = Path.join(folder, "#{hash}.png")
    dated = Path.join(folder, "#{hash}-20260913-220000.png")

    File.write!(quick, "quick")
    File.write!(dated, "dated")
    File.write!(Path.join(folder, "#{other_hash}.png"), "other")
    File.write!(Path.join(folder, "notes.txt"), "not a state")

    assert MapSet.new(SaveState.list(folder, hash)) == MapSet.new([quick, dated])
    assert SaveState.label(quick, hash) == "Quick state"
    assert SaveState.label(dated, hash) == "20260913 220000"
  end
end
