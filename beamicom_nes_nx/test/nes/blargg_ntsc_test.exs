defmodule Beamicom.NES.Nx.BlarggNTSCTest do
  use ExUnit.Case, async: false

  alias Beamicom.Host.VideoFrame
  alias Beamicom.NES.Nx, as: NESNx
  alias Beamicom.NES.Nx.BlarggNTSC
  alias Beamicom.NES.{SaveState, System}

  test "standard setup tables remain byte-identical to nes_ntsc 0.2.2" do
    expected = %{
      composite: "ba43fbb60e03cce263aa33425c7ecee9828d52a8d208a5b2b8d014baba6be244",
      svideo: "ca60b80dfca302693a80babd32bbe4e60d09a6d9ac9ff1be2c09091c7ccbf24d",
      rgb: "9313d547425dfcc0afaa9fed0cc143f15793f02aeb1cbd4e85f182700b74bc45",
      monochrome: "d5946366cad6cf849f6f00e973d2011a0f08b57fdf9a29dfe4883b14932a32e8"
    }

    for {preset, hash} <- expected do
      table = BlarggNTSC.Table.generate(preset)
      assert digest(Nx.to_binary(table)) == hash
    end
  end

  test "runtime setup overrides produce a distinct resident table" do
    standard = BlarggNTSC.prepare(preset: :composite)
    adjusted = BlarggNTSC.prepare(preset: :composite, hue: 0.25, saturation: -0.2)

    assert Nx.shape(standard.table) == {8192}
    assert Nx.type(standard.table) == {:s, 32}
    refute Nx.to_binary(standard.table) == Nx.to_binary(adjusted.table)
  end

  test "out-of-range setup overrides retain wide kernel storage" do
    state = BlarggNTSC.prepare(preset: :composite, brightness: 10.0)
    assert Nx.type(state.table) == {:s, 64}
  end

  test "Nx blitter is byte-identical to the reference RGB565 output" do
    pixels =
      for y <- 0..239, x <- 0..255, into: <<>> do
        <<Bitwise.band(x * 5 + y * 3 + div(x, 7), 31)>>
      end

    palette = 0..31 |> Enum.to_list() |> :binary.list_to_bin()
    masks = :binary.copy(<<0>>, 240)
    rgb = BlarggNTSC.filter(pixels, palette, masks, 0, 0, BlarggNTSC.prepare())

    rgb565 =
      for <<red, green, blue <- rgb>>, into: <<>> do
        pixel =
          Bitwise.bor(
            Bitwise.bor(
              Bitwise.bsl(Bitwise.band(red, 0xF8), 8),
              Bitwise.bsl(Bitwise.band(green, 0xFC), 3)
            ),
            Bitwise.bsr(blue, 3)
          )

        <<pixel::native-16>>
      end

    assert byte_size(rgb) == 602 * 240 * 3
    assert digest(rgb565) == "8150dfd7b44b13e2d0e5e5c922619e74b5153d15f2286f4397f1d161dba9614d"
  end

  test "runtime load option publishes widened presentation geometry" do
    options = NESNx.video_options(:composite)
    capabilities = NESNx.video_capabilities(:composite)

    assert capabilities.video.width == 602
    assert capabilities.video.height == 240
    assert capabilities.video.pixel_scale == {1, 2}
    assert {:ok, console} = System.load(minimal_rom(), options)

    assert {_console, [%VideoFrame{} = video, _audio]} = System.run_slice(console)
    assert video.width == 602
    assert video.height == 240
    assert byte_size(video.data.pixels) == 256 * 240
    assert byte_size(video.data.rgb) == 602 * 240 * 3
  end

  test "filter falls back to byte capture for CHR RAM cartridges" do
    options = NESNx.video_options(:composite)
    assert {:ok, console} = System.load(minimal_rom(0), options)

    assert {_console, [%VideoFrame{} = video, _audio]} = System.run_slice(console)
    assert video.width == 602
    assert video.height == 240
    assert byte_size(video.data.pixels) == 256 * 240
    assert byte_size(video.data.rgb) == 602 * 240 * 3
  end

  test "save-state restore preserves the selected filter setup" do
    options = NESNx.video_options(:svideo, merge_fields: false)
    assert {:ok, console} = System.load(minimal_rom(), options)

    {state, rom} = SaveState.split(console)
    assert {:ok, restored} = SaveState.merge(state, rom)

    assert restored.bus.ppu.renderer == Beamicom.NES.Nx.BlarggNTSC.Renderer
    assert restored.bus.ppu.renderer_options[:preset] == :svideo
    assert restored.bus.ppu.renderer_options[:merge_fields] == false
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp minimal_rom(chr_banks \\ 1) do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, chr_banks, 0::size(10 * 8)>> <> prg <> :binary.copy(<<0>>, chr_banks * 8192)
  end
end
