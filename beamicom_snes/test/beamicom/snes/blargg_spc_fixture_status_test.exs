defmodule Beamicom.SNES.BlarggSPCFixtureStatusTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.ConformanceROM

  for fixture <- ConformanceROM.fixture_names(:blargg_spc6) do
    if ConformanceROM.fixture_available?(fixture) do
      test "#{fixture}: pass if SHA-256 matches; fail otherwise" do
        fixture = unquote(fixture)

        assert fixture
               |> ConformanceROM.verify_fixture!()
               |> byte_size() > 0
      end
    else
      @tag skip:
             "skipped: fixture missing; see test/fixtures/snes_conformance/blargg-spc-6/README.md"

      test "#{fixture}: skipped: fixture missing" do
        flunk("fixture availability changed after this test was compiled")
      end
    end
  end
end
