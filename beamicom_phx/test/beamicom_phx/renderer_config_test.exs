defmodule BeamicomPhx.RendererConfigTest do
  use ExUnit.Case, async: true

  test "compiles both emulator cores against the included Nx renderers" do
    assert Beamicom.NES.PPU.configured_renderer() == Beamicom.NES.Nx.PPURenderer
    assert Beamicom.NES.Bus.configured_apu_renderer() == Beamicom.NES.Nx.APUBlockRenderer
    assert Beamicom.GB.PPU.configured_renderer() == Beamicom.GB.Nx.PPURenderer
    assert Beamicom.GB.APU.configured_renderer() == Beamicom.GB.Nx.APUSynthRenderer
  end
end
