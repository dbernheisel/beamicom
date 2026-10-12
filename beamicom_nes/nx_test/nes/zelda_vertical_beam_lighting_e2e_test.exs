defmodule Beamicom.NES.Nx.ZeldaVerticalBeamLightingE2ETest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.NES.{Console, PPU, ShareImage, System}
  alias Beamicom.NES.Nx.{Lighting, PPURenderer}

  @rom Path.expand("../../roms/zelda.nes", __DIR__)
  @state Elixir.System.get_env("BEAMICOM_ZELDA_VERTICAL_BEAM_STATE") || ""
  @state_sha256 "ec733e24bf89b9971f03acbf7d50324b298760bd8df2a56ef2314dff832da6ae"

  @moduletag :e2e
  @moduletag skip:
               if(is_binary(@state) and File.regular?(@state) and File.regular?(@rom),
                 do: false,
                 else:
                   "set BEAMICOM_ZELDA_VERTICAL_BEAM_STATE to the Zelda vertical-beam checkpoint"
               )

  setup_all do
    rom = File.read!(@rom)
    state = File.read!(@state)

    assert digest(state) == @state_sha256
    assert Lighting.content_hash(rom) == Lighting.zelda_hash()
    assert {:ok, lighting} = Lighting.for_rom(rom)
    assert {:ok, base_checkpoint} = ShareImage.load_image(state, [Path.dirname(@rom)])
    assert {:ok, lit_checkpoint} = ShareImage.load_image(state, [Path.dirname(@rom)])

    %{base_checkpoint: base_checkpoint, lit_checkpoint: lit_checkpoint, lighting: lighting}
  end

  test "the vertical traveling beam emits while preserving native pixels",
       %{base_checkpoint: base_checkpoint, lit_checkpoint: lit_checkpoint, lighting: lighting} do
    assert vertical_beam_visible?(base_checkpoint.bus.ppu)

    {_base, base_frame} = base_checkpoint |> configure({PPURenderer, []}) |> next_frame()

    {_lit, lit_frame} =
      lit_checkpoint |> configure({PPURenderer, lighting: lighting}) |> next_frame()

    assert base_frame.pixels == lit_frame.pixels
    assert different_pixels(base_frame, lit_frame, 116..139, 190..218) > 0
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

  defp vertical_beam_visible?(ppu) do
    sprites = for <<y, tile, attr, x <- ppu.oam>>, y < 0xEF, do: {x, y, tile, attr &&& 0x03}
    {124, 194, 32, 2} in sprites
  end

  defp different_pixels(base, lit, xs, ys) do
    Enum.count(for(y <- ys, x <- xs, do: {x, y}), fn {x, y} ->
      offset = (y * base.rgb_width + x) * 3
      binary_part(base.rgb, offset, 3) != binary_part(lit.rgb, offset, 3)
    end)
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
