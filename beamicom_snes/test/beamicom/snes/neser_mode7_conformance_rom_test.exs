defmodule Beamicom.SNES.NeserMode7ConformanceROMTest do
  use ExUnit.Case, async: false

  alias Beamicom.SNES.ConformanceROM

  @fixtures ConformanceROM.fixture_names(:neser_mode7)
  @moduletag :conformance
  @moduletag timeout: 120_000
  @moduletag skip: not ConformanceROM.fixtures_available?(@fixtures)

  test "NESER Mode 7 ROMs retain their attributed upstream bytes" do
    for fixture <- @fixtures do
      assert fixture |> ConformanceROM.verify_fixture!() |> byte_size() > 0
    end
  end

  for fixture <- @fixtures do
    test "#{fixture} matches its Mesen2-approved framebuffer" do
      fixture = unquote(fixture)
      %{machine: machine, frame: frame} = ConformanceROM.run_frames!(fixture, 68)

      assert machine.bus.ppu.bg_mode == 7
      assert machine.bus.apu.spc.error == nil
      assert :erlang.crc32(frame.data) == ConformanceROM.expected_frame_crc32(fixture)
    end
  end
end
