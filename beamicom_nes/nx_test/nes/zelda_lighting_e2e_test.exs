defmodule Beamicom.NES.Nx.ZeldaLightingE2ETest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.NES.{Bus, Console, PPU, ShareImage, System}
  alias Beamicom.NES.Nx.{Lighting, PPURenderer}
  alias Beamicom.NES.Nx.BlarggNTSC.Renderer, as: BlarggRenderer

  @rom Path.expand("../../roms/zelda.nes", __DIR__)
  @state Elixir.System.get_env("BEAMICOM_ZELDA_STATE") || ""
  @state_sha256 "7510ee3773e0e758314e02cc63841f25c127bc7a7bf21fe5281d714cbe1c2433"
  @supplemental_states [
    rupee:
      {Elixir.System.get_env("BEAMICOM_ZELDA_RUPEE_STATE") || "",
       "8c1b14ab538fb722aa6db11b5aebb7c3143ea9bc3c733ffd82c31f0e1f8804cb", 50, 48..63, 168..191},
    clock_flash_link:
      {Elixir.System.get_env("BEAMICOM_ZELDA_CLOCK_STATE") || "",
       "c4443a8540df3358249e37b70bcf277abf1245ccf30619120aa2bef60b4f40c7", 4, 76..103, 188..215},
    enemy_fireball:
      {Elixir.System.get_env("BEAMICOM_ZELDA_FIREBALL_STATE") || "",
       "97d531081d2e75195953e15aca4bd38f7157fb2de0e0af6b7342d757d66ca2c2", 68, 48..67, 158..181},
    heart_pickup:
      {Elixir.System.get_env("BEAMICOM_ZELDA_HEART_STATE") || "",
       "80a6e6a70f3447bd8d78402cf45615b32dbbfc275267d645cab67c3adb7f125b", 498, 179..198,
       122..145}
  ]
  @supplemental_ready Enum.all?(@supplemental_states, fn {_name, {path, _, _, _, _}} ->
                        File.regular?(path)
                      end)

  @moduletag :e2e
  @moduletag skip:
               if(is_binary(@state) and File.regular?(@state) and File.regular?(@rom),
                 do: false,
                 else:
                   "set BEAMICOM_ZELDA_STATE to the Zelda lighting checkpoint and provide roms/zelda.nes"
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

  test "verified Zelda emitters survive every enhancement and post-processing combination",
       %{checkpoint: checkpoint, lighting: lighting} do
    renderers = [
      {:native, PPURenderer, 256},
      {:composite, BlarggRenderer, 602},
      {:svideo, BlarggRenderer, 602},
      {:rgb, BlarggRenderer, 602},
      {:monochrome, BlarggRenderer, 602}
    ]

    for {preset, renderer, width} <- renderers,
        unlimited_sprites <- [false, true],
        hide_horizontal_overscan <- [false, true] do
      base_options = renderer_options(preset, nil)
      lit_options = renderer_options(preset, lighting)

      enhancements = [
        unlimited_sprites: unlimited_sprites,
        hide_horizontal_overscan: hide_horizontal_overscan
      ]

      {_base_console, base} = render(checkpoint, {renderer, base_options}, enhancements)
      {_lit_console, lit} = render(checkpoint, {renderer, lit_options}, enhancements)

      assert lit.pixels == base.pixels
      refute lit.rgb == base.rgb
      assert lit.rgb_width == width
      assert lit.rgb_height == 240
      assert byte_size(lit.rgb) == width * 240 * 3

      if hide_horizontal_overscan do
        assert black_output_edges?(lit)
      end
    end
  end

  test "the real flame, sword, traveling beam, and beam particles emit from verified slots",
       %{checkpoint: checkpoint, lighting: lighting} do
    base = configure(checkpoint, {PPURenderer, []}, [])
    lit = configure(checkpoint, {PPURenderer, lighting: lighting}, [])

    {base, base_frame} = next_frame(base, [])
    {lit, lit_frame} = next_frame(lit, [])

    assert base_frame.pixels == lit_frame.pixels
    assert different_pixels(base_frame, lit_frame, 68..87, 124..146) > 0
    assert different_pixels(base_frame, lit_frame, 128..151, 148..170) > 0
    assert flame_tiles_visible?(lit.bus.ppu)
    assert sword_tiles_visible?(lit.bus.ppu)

    {base, lit, beam_base, beam_lit} =
      run_until(base, lit, 0xBA, 0x10, [[:a], [:a] | List.duplicate([], 30)])

    beam_x = Bus.peek(lit.bus, 0x7E)
    beam_y = Bus.peek(lit.bus, 0x92)
    assert beam_base.pixels == beam_lit.pixels

    assert different_pixels(
             beam_base,
             beam_lit,
             beam_x..min(beam_x + 23, 255),
             beam_y..(beam_y + 15)
           ) > 0

    assert sword_tiles_visible?(lit.bus.ppu)

    {base, lit, _burst_base, _burst_lit} =
      run_until(base, lit, 0xBA, 0x11, List.duplicate([], 60))

    {base, _burst_base} = next_frame(base, [])
    {lit, _burst_lit} = next_frame(lit, [])
    {_base, burst_base} = next_frame(base, [])
    {lit, burst_lit} = next_frame(lit, [])

    assert burst_base.pixels == burst_lit.pixels
    assert beam_particle_tiles_visible?(lit.bus.ppu)
    assert different_pixels(burst_base, burst_lit, 228..255, 140..172) > 0
  end

  @tag skip:
         if(@supplemental_ready,
           do: false,
           else: "set the BEAMICOM_ZELDA_{RUPEE,CLOCK,FIREBALL,HEART}_STATE checkpoints"
         )
  test "rupee, clock-flashing Link, enemy fireball, and heart checkpoints emit",
       %{lighting: lighting} do
    for {name, {path, sha256, tile, xs, ys}} <- @supplemental_states do
      message = Atom.to_string(name)
      state = File.read!(path)
      assert digest(state) == sha256
      assert {:ok, checkpoint} = ShareImage.load_image(state, [Path.dirname(@rom)])

      base = configure(checkpoint, {PPURenderer, []}, [])
      lit = configure(checkpoint, {PPURenderer, lighting: lighting}, [])
      {_base, base_frame} = next_frame(base, [])
      {lit, lit_frame} = next_frame(lit, [])

      assert base_frame.pixels == lit_frame.pixels, message
      assert tile in visible_tiles(lit.bus.ppu), message
      assert different_pixels(base_frame, lit_frame, xs, ys) > 0, message
    end
  end

  defp renderer_options(:native, nil), do: []
  defp renderer_options(:native, lighting), do: [lighting: lighting]
  defp renderer_options(preset, nil), do: [preset: preset]
  defp renderer_options(preset, lighting), do: [preset: preset, lighting: lighting]

  defp render(checkpoint, renderer, enhancements) do
    checkpoint
    |> configure(renderer, enhancements)
    |> next_frame([])
  end

  defp configure(checkpoint, renderer, enhancements) do
    ppu = PPU.set_renderer(checkpoint.bus.ppu, renderer)
    console = %{checkpoint | bus: %{checkpoint.bus | ppu: ppu}}

    Enum.reduce(enhancements, console, fn {enhancement, enabled}, console ->
      Console.set_enhancement(console, enhancement, enabled)
    end)
  end

  defp next_frame(console, buttons) do
    console = Console.set_buttons(console, 1, buttons)
    {console, [video, _audio]} = System.run_slice(console)
    {console, video.data}
  end

  defp run_until(base, lit, address, value, inputs) do
    Enum.reduce_while(inputs, {base, lit, nil, nil}, fn buttons, {base, lit, _, _} ->
      {base, base_frame} = next_frame(base, buttons)
      {lit, lit_frame} = next_frame(lit, buttons)

      if Bus.peek(lit.bus, address) == value,
        do: {:halt, {base, lit, base_frame, lit_frame}},
        else: {:cont, {base, lit, base_frame, lit_frame}}
    end)
    |> tap(fn {console, _lit, _base_frame, _lit_frame} ->
      assert Bus.peek(console.bus, address) == value
    end)
  end

  defp different_pixels(base, lit, xs, ys) do
    Enum.count(for(y <- ys, x <- xs, do: {x, y}), fn {x, y} ->
      offset = (y * base.rgb_width + x) * 3
      binary_part(base.rgb, offset, 3) != binary_part(lit.rgb, offset, 3)
    end)
  end

  defp flame_tiles_visible?(ppu), do: visible_tiles(ppu) |> Enum.any?(&(&1 in 92..95))
  defp sword_tiles_visible?(ppu), do: visible_tiles(ppu) |> Enum.any?(&(&1 in 130..133))
  defp beam_particle_tiles_visible?(ppu), do: visible_tiles(ppu) |> Enum.any?(&(&1 in 48..49))

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

  defp black_output_edges?(frame) do
    left = binary_part(frame.rgb, 0, 3)
    right = binary_part(frame.rgb, (frame.rgb_width - 1) * 3, 3)
    left == <<0, 0, 0>> and right == <<0, 0, 0>>
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
