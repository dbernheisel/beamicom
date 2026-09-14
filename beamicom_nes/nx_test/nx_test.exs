defmodule Beamicom.NES.NxTest do
  use ExUnit.Case, async: false

  test "wrapper compiles the core against both optional renderers" do
    assert Beamicom.NES.Nx.backends() == %{
             ppu: Beamicom.NES.Nx.PPURenderer,
             apu: Beamicom.NES.Nx.APUBlockRenderer
           }
  end

  test "Zelda lights the full flame palette without treating Link as an emitter" do
    emitters = Beamicom.NES.Nx.Lighting.zelda() |> Keyword.fetch!(:emitters)
    flame = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :flame))
    enemy_death = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :enemy_death))

    assert Keyword.fetch!(flame, :color_slots) == [1, 2, 3]
    assert Keyword.fetch!(enemy_death, :tiles) == [98, 100]
    assert Keyword.fetch!(enemy_death, :subpalettes) == [0, 1, 2, 3]
    assert Keyword.fetch!(enemy_death, :color_slots) == [1, 2, 3]
    refute Enum.any?(emitters, &(Keyword.fetch!(&1, :id) == :clock_flash_link))
  end
end
