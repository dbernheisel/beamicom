defmodule Beamicom.NES.Nx.ZeldaCandleLightingE2ETest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.NES.{Console, PPU, ShareImage, System}
  alias Beamicom.NES.Nx.{Lighting, PPURenderer}

  @rom Path.expand("../../roms/zelda.nes", __DIR__)
  @state Elixir.System.get_env("BEAMICOM_ZELDA_CANDLE_STATE") || ""
  @state_sha256 "83c0ff779de76d4857ac1b89518f857dbeb158f9049efdecd2106132dc53815b"

  @moduletag :e2e
  @moduletag skip:
               if(is_binary(@state) and File.regular?(@state) and File.regular?(@rom),
                 do: false,
                 else: "set BEAMICOM_ZELDA_CANDLE_STATE to the Zelda candle checkpoint"
               )

  setup_all do
    rom = File.read!(@rom)
    state = File.read!(@state)

    assert digest(state) == @state_sha256
    assert Lighting.content_hash(rom) == Lighting.zelda_hash()
    assert {:ok, lighting} = Lighting.for_rom(rom)
    assert {:ok, checkpoint} = ShareImage.load_image(state, [Path.dirname(@rom)])

    %{checkpoint: checkpoint, lighting: lighting}
  end

  test "the candle tip emits without treating the neighboring key as an emitter",
       %{checkpoint: checkpoint, lighting: lighting} do
    assert candle_and_key_visible?(checkpoint.bus.ppu)

    {_base, base_frame} = checkpoint |> configure({PPURenderer, []}) |> next_frame()
    {_lit, lit_frame} = checkpoint |> configure({PPURenderer, lighting: lighting}) |> next_frame()

    assert base_frame.pixels == lit_frame.pixels
    assert different_pixels(base_frame, lit_frame, 146..174, 143..177) > 0
    assert different_pixels(base_frame, lit_frame, 118..140, 150..171) == 0
  end

  defp configure(checkpoint, renderer) do
    ppu = PPU.set_renderer(checkpoint.bus.ppu, renderer)
    %{checkpoint | bus: %{checkpoint.bus | ppu: ppu}}
  end

  defp next_frame(console) do
    console = Console.set_buttons(console, 1, [])
    {console, [video, _audio]} = System.run_slice(console)
    {console, video.data}
  end

  defp candle_and_key_visible?(ppu) do
    sprites = for <<y, tile, attr, _x <- ppu.oam>>, y < 0xEF, do: {tile, attr &&& 0x03}
    {38, 1} in sprites and {46, 2} in sprites
  end

  defp different_pixels(base, lit, xs, ys) do
    Enum.count(for(y <- ys, x <- xs, do: {x, y}), fn {x, y} ->
      offset = (y * base.rgb_width + x) * 3
      binary_part(base.rgb, offset, 3) != binary_part(lit.rgb, offset, 3)
    end)
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
