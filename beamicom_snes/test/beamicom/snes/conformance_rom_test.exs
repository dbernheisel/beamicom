defmodule Beamicom.SNES.ConformanceROMTest do
  use ExUnit.Case, async: false

  alias Beamicom.SNES.ConformanceROM

  @fixtures ConformanceROM.fixture_names(:blargg_spc6)
  @moduletag skip: not ConformanceROM.fixtures_available?(@fixtures)

  test "vendored Blargg SPC ROMs retain their attributed upstream bytes" do
    for fixture <- @fixtures do
      assert fixture |> ConformanceROM.verify_fixture!() |> byte_size() > 0
    end
  end

  for fixture <- @fixtures do
    test "#{fixture} boots, renders, and advances both processors" do
      fixture = unquote(fixture)
      %{machine: machine, frame: frame} = ConformanceROM.run_frames!(fixture, 8)

      assert machine.cpu.instructions > 100_000
      assert machine.bus.apu.spc.cycles > 100_000
      assert machine.bus.apu.spc.error == nil
      refute machine.bus.apu.spc.pc in 0xFFC0..0xFFFF

      assert %{width: 256, height: 224, pixel_format: :rgb24} = frame
      refute frame.data == :binary.copy(<<0>>, byte_size(frame.data))
    end
  end

  for fixture <- @fixtures do
    @tag :conformance
    @tag timeout: 120_000
    test "#{fixture} does not report a failure in its first 120 frames" do
      fixture = unquote(fixture)
      %{frame: frame} = ConformanceROM.run_frames!(fixture, 120)

      refute ConformanceROM.failure_screen?(frame),
             "#{fixture} reached Blargg's red failure screen"
    end
  end
end
