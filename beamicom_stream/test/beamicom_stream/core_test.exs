defmodule BeamicomStream.CoreTest do
  use ExUnit.Case, async: true

  alias BeamicomStream.Core

  test "selects static NES and Game Boy integrations by media extension" do
    assert {:ok, %{id: :nes, system: Beamicom.NES.System, runtime: :nes} = nes} =
             Core.resolve("game.NES")

    assert nes.capabilities.video == Beamicom.NES.System.capabilities().video
    assert nes.capabilities.audio.channels == 1
    assert Map.has_key?(nes.capabilities.input.ports, 2)

    for extension <- ["gb", "gbc", "GBC"] do
      assert {:ok, %{id: :gbc, system: Beamicom.GB.System, runtime: :host} = gb} =
               Core.resolve("game.#{extension}")

      assert {gb.capabilities.video.width, gb.capabilities.video.height} == {160, 144}
      assert gb.capabilities.audio.channels == 2
      refute Map.has_key?(gb.capabilities.input.ports, 2)
    end
  end

  test "rejects media that no compiled core owns" do
    assert {:error, {:unsupported_media_extension, ".smc"}} = Core.resolve("game.smc")
    assert {:error, {:unsupported_media_extension, ""}} = Core.resolve("game")
  end
end
