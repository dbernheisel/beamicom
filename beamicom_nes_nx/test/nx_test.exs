defmodule Beamicom.NES.NxTest do
  use ExUnit.Case, async: false

  test "enables and disables both optional renderers" do
    on_exit(fn -> Beamicom.NES.Nx.enable() end)

    assert :ok = Beamicom.NES.Nx.disable()
    assert Application.get_env(:beamicom_nes, :ppu_renderer) == :native
    assert Application.get_env(:beamicom_nes, :apu_renderer) == :native

    assert :ok = Beamicom.NES.Nx.enable()

    assert Application.get_env(:beamicom_nes, :ppu_renderer) ==
             Beamicom.NES.Nx.PPUAtlasRenderer

    assert Application.get_env(:beamicom_nes, :apu_renderer) ==
             Beamicom.NES.Nx.APUBlockRenderer
  end
end
