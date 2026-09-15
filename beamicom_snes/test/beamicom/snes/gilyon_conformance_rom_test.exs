defmodule Beamicom.SNES.GilyonConformanceROMTest do
  use ExUnit.Case, async: false

  alias Beamicom.SNES.ConformanceROM

  @fixtures ConformanceROM.fixture_names(:gilyon)
  @cpu_fixtures [:gilyon_cpu_basic, :gilyon_cpu_full]
  @moduletag skip: not ConformanceROM.fixtures_available?(@fixtures)

  test "vendored Gilyon ROMs retain their attributed upstream bytes" do
    for fixture <- @fixtures do
      assert fixture |> ConformanceROM.verify_fixture!() |> byte_size() > 0
    end
  end

  for fixture <- @cpu_fixtures do
    test "#{fixture} boots and renders while exercising the 65C816" do
      fixture = unquote(fixture)
      %{machine: machine, frame: frame} = ConformanceROM.run_frames!(fixture, 8)

      assert machine.cpu.instructions > 80_000
      assert %{width: 256, height: 224, pixel_format: :rgb24} = frame
      refute frame.data == :binary.copy(<<0>>, byte_size(frame.data))
    end
  end

  test "gilyon_spc boots its SPC program and renders progress" do
    %{machine: machine, frame: frame} = ConformanceROM.run_frames!(:gilyon_spc, 12)

    assert machine.cpu.instructions > 100_000
    assert machine.bus.apu.spc.cycles > 10_000
    assert machine.bus.apu.spc.error == nil
    assert %{width: 256, height: 224, pixel_format: :rgb24} = frame
    refute frame.data == :binary.copy(<<0>>, byte_size(frame.data))
  end

  for fixture <- @fixtures do
    @tag :conformance
    @tag timeout: 120_000
    test "#{fixture} reports success within 240 frames" do
      fixture = unquote(fixture)
      result = ConformanceROM.run_until_gilyon_result!(fixture, 240)

      assert match?({:passed, _test_number}, result.status),
             "#{fixture} ended with #{format_status(result.status)} after #{result.frames} frames"
    end
  end

  defp format_status(:running), do: "no terminal result"

  defp format_status({status, nil}), do: Atom.to_string(status)

  defp format_status({status, test_number}) do
    "#{status} at test #{test_number |> Integer.to_string(16) |> String.pad_leading(4, "0")}"
  end
end
