defmodule Beamicom.Scenic.CoreTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Core

  test "selects NES and Game Boy cores without loading Scenic" do
    assert {:ok, %Core{id: :nes, runtime: :nes, system: Beamicom.NES.System}} =
             Core.resolve("GAME.NES")

    assert {:ok, %Core{id: :nes, runtime: :nes}} = Core.resolve("save.png")

    for extension <- ["gb", "gbc", "GBC"] do
      assert {:ok, %Core{id: :gbc, runtime: :host, system: Beamicom.GB.System}} =
               Core.resolve("game.#{extension}")
    end

    assert {:error, {:unsupported_media_extension, ".smc"}} = Core.resolve("game.smc")
  end

  test "reports each core's native dimensions and audio layout" do
    {:ok, nes} = Core.resolve("game.nes")
    {:ok, gbc} = Core.resolve("game.gbc")

    assert nes.capabilities.video.width == 256
    assert nes.capabilities.video.height == 240
    assert nes.capabilities.audio.channels == 1

    assert gbc.capabilities.video.width == 160
    assert gbc.capabilities.video.height == 144
    assert gbc.capabilities.audio.channels == 2
  end

  test "routes and loads an iNES ROM by magic with a nonstandard extension" do
    media = minimal_nes_rom()

    assert {:ok, %Core{id: :nes} = core} = Core.resolve("renamed.rom", media)
    assert {:ok, %Beamicom.NES.Console{}} = Core.load(core, media, [])

    assert {:ok, %Core{id: :nes}} =
             Core.resolve("renamed.data", <<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
  end

  defp minimal_nes_rom do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, 1, 0::size(10 * 8)>> <> prg <> <<0::size(8192 * 8)>>
  end
end
