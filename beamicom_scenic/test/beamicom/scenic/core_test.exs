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

    for extension <- ["sfc", "smc", "SFC"] do
      assert {:ok, %Core{id: :snes, runtime: :host, system: Beamicom.Scenic.SNESSystem}} =
               Core.resolve("game.#{extension}")
    end

    assert {:error, {:unsupported_media_extension, ".fig"}} = Core.resolve("game.fig")
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

    {:ok, snes} = Core.resolve("game.sfc")
    assert snes.capabilities.video.width == 256
    assert snes.capabilities.video.height == 224
    assert snes.capabilities.audio.channels == 2
  end

  test "reports the runtime NTSC filter's presentation geometry" do
    capabilities = Beamicom.NES.Nx.video_capabilities(:composite)

    assert capabilities.video.width == 602
    assert capabilities.video.height == 240
    assert capabilities.video.pixel_scale == {1, 2}
  end

  test "local display does not impose Scenic's default 29 ms stream throttle" do
    viewport = Application.fetch_env!(:beamicom_scenic, :viewport)

    local_driver =
      viewport
      |> Keyword.fetch!(:drivers)
      |> Enum.find(&(Keyword.get(&1, :module) == Scenic.Driver.Local))

    assert local_driver[:limit_ms] == 0
    assert local_driver[:position] == [scaled: false, centered: false]
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
