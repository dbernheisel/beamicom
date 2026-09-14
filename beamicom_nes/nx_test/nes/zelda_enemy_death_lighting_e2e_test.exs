defmodule Beamicom.NES.Nx.ZeldaEnemyDeathLightingE2ETest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.NES.{Console, PPU, ShareImage, System}
  alias Beamicom.NES.Nx.{Lighting, PPURenderer}

  @rom Path.expand("../../roms/zelda.nes", __DIR__)
  @state Elixir.System.get_env("BEAMICOM_ZELDA_DEATH_STATE") || ""
  @state_sha256 "75888cb9d709dd9951beb473f409314c163af87bdfab06e8ec7238ceaab709f9"
  @death_tiles [98, 100]

  @moduletag :e2e
  @moduletag skip:
               if(is_binary(@state) and File.regular?(@state) and File.regular?(@rom),
                 do: false,
                 else: "set BEAMICOM_ZELDA_DEATH_STATE to the Zelda enemy-death checkpoint"
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

  test "the complete enemy death burst emits while preserving native pixels",
       %{checkpoint: checkpoint, lighting: lighting} do
    base = configure(checkpoint, {PPURenderer, []})
    lit = configure(checkpoint, {PPURenderer, lighting: lighting})

    {_base, lit, emitting_frames} =
      Enum.reduce(1..20, {base, lit, 0}, fn _frame, {base, lit, emitting_frames} ->
        {base, base_frame} = next_frame(base)
        {lit, lit_frame} = next_frame(lit)

        assert base_frame.pixels == lit_frame.pixels

        if death_tiles_visible?(lit.bus.ppu) do
          assert different_pixels(base_frame, lit_frame, 153..181, 134..158) > 0
          {base, lit, emitting_frames + 1}
        else
          {base, lit, emitting_frames}
        end
      end)

    assert emitting_frames >= 10
    refute death_tiles_visible?(lit.bus.ppu)
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

  defp death_tiles_visible?(ppu) do
    Enum.any?(visible_tiles(ppu), &(&1 in @death_tiles))
  end

  defp visible_tiles(ppu) do
    for <<y, tile, _attr, _x <- ppu.oam>>,
        y < 0xEF,
        logical <- logical_tiles(ppu, tile),
        do: logical
  end

  defp logical_tiles(ppu, tile) when (ppu.ctrl &&& 0x20) == 0,
    do: [(ppu.ctrl &&& 0x08) * 0x20 + tile]

  defp logical_tiles(_ppu, tile) do
    base = ((tile &&& 1) <<< 8) + (tile &&& 0xFE)
    [base, base + 1]
  end

  defp different_pixels(base, lit, xs, ys) do
    Enum.count(for(y <- ys, x <- xs, do: {x, y}), fn {x, y} ->
      offset = (y * base.rgb_width + x) * 3
      binary_part(base.rgb, offset, 3) != binary_part(lit.rgb, offset, 3)
    end)
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
