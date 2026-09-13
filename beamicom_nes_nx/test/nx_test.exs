defmodule Beamicom.NES.NxTest do
  use ExUnit.Case, async: false

  test "wrapper compiles the core against both optional renderers" do
    assert Beamicom.NES.Nx.backends() == %{
             ppu: Beamicom.NES.Nx.PPUAtlasRenderer,
             apu: Beamicom.NES.Nx.APUBlockRenderer
           }
  end
end
