defmodule Beamicom.NES.NxTest do
  use ExUnit.Case, async: false

  test "wrapper compiles the core against both optional renderers" do
    apu_renderer =
      if System.get_env("BEAMICOM_AUDIO_48") in ["1", "true", "yes", "on"],
        do: Beamicom.NES.Nx.FrameAPURenderer,
        else: Beamicom.NES.Nx.APUBlockRenderer

    assert Beamicom.NES.Nx.backends() == %{
             ppu: Beamicom.NES.Nx.PPURenderer,
             apu: apu_renderer
           }
  end

  test "Zelda lights the full flame palette without treating Link as an emitter" do
    emitters = Beamicom.NES.Nx.Lighting.zelda() |> Keyword.fetch!(:emitters)
    flame = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :flame))
    enemy_death = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :enemy_death))
    blue_candle = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :blue_candle_tip))
    red_candle = Enum.find(emitters, &(Keyword.fetch!(&1, :id) == :red_candle_tip))

    assert Keyword.fetch!(flame, :color_slots) == [1, 2, 3]
    assert Keyword.fetch!(enemy_death, :tiles) == [98, 100]
    assert Keyword.fetch!(enemy_death, :subpalettes) == [0, 1, 2, 3]
    assert Keyword.fetch!(enemy_death, :color_slots) == [1, 2, 3]

    assert Keyword.take(blue_candle, [:tiles, :subpalettes, :color_slots, :rows, :intensity]) == [
             tiles: [38],
             subpalettes: [1],
             color_slots: [1, 2],
             rows: 0..4,
             intensity: 1.5
           ]

    assert Keyword.take(red_candle, [:tiles, :subpalettes, :color_slots, :rows, :intensity]) == [
             tiles: [38],
             subpalettes: [2],
             color_slots: [1, 2],
             rows: 0..4,
             intensity: 1.0
           ]

    refute Enum.any?(emitters, &(46 in Keyword.fetch!(&1, :tiles)))
    refute Enum.any?(emitters, &(Keyword.fetch!(&1, :id) == :clock_flash_link))
  end
end
