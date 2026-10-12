defmodule Beamicom.GBA.PPUTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.PPU

  defmodule MarkerRenderer do
    @behaviour Beamicom.GBA.PPURenderer

    @frame_bytes 240 * 160 * 3

    @impl true
    def render_mode0(<<marker, _rest::binary>>, _palette, _oam, _registers),
      do: :binary.copy(<<marker>>, @frame_bytes)

    @impl true
    def render_mode1(vram, palette, oam, registers),
      do: render_mode0(vram, palette, oam, registers)

    @impl true
    def render_mode3(vram, palette, oam, registers),
      do: render_mode0(vram, palette, oam, registers)
  end

  test "renders visible memory at VBlank entry and publishes it at line zero" do
    ppu = %{PPU.new(renderer: MarkerRenderer) | line: 159, phase: :hblank}
    ppu = PPU.begin_next_line(ppu, <<0xAA>>, <<>>, <<>>)

    assert ppu.line == 160
    assert ppu.frame_number == 0
    assert binary_part(ppu.frame, 0, 1) == <<0xAA>>

    ppu = %{ppu | line: 227, phase: :vblank}
    ppu = PPU.begin_next_line(ppu, <<0xBB>>, <<>>, <<>>)

    assert ppu.line == 0
    assert ppu.frame_number == 1
    assert binary_part(ppu.frame, 0, 1) == <<0xAA>>
  end

  test "captures display state and effective affine references for each scanline" do
    ppu =
      [
        {0x20, 0x00},
        {0x21, 0x01},
        {0x22, 0x00},
        {0x23, 0x01},
        {0x24, 0x00},
        {0x25, 0x00},
        {0x26, 0x00},
        {0x27, 0x02},
        {0x28, 0x00},
        {0x29, 0x10},
        {0x2A, 0x00},
        {0x2B, 0x00},
        {0x2C, 0x00},
        {0x2D, 0x20},
        {0x2E, 0x00},
        {0x2F, 0x00}
      ]
      |> Enum.reduce(PPU.new() |> PPU.enter_hblank(), fn {offset, value}, ppu ->
        PPU.put_affine_register(ppu, offset, value)
      end)
      |> PPU.put_dispcnt(0x3F41)
      |> PPU.put_background_register(0x0C, 0x89)
      |> PPU.put_background_register(0x0D, 0xF8)

    ppu = PPU.begin_next_line(ppu, <<>>, <<>>, <<>>)

    assert elem(ppu.scanline_dispcnt, 1) == 0x3F41
    assert elem(ppu.scanline_bgcnt, 1) |> elem(2) == 0xF889

    assert elem(ppu.scanline_bg_affine, 1) |> elem(0) ==
             {0x0100, 0x0100, 0, 0x0200, 0x1000, 0x2000}

    ppu = PPU.begin_next_line(ppu, <<>>, <<>>, <<>>)

    assert elem(ppu.scanline_bg_affine, 2) |> elem(0) ==
             {0x0100, 0x0100, 0, 0x0200, 0x1100, 0x2200}

    ppu = PPU.enter_hblank(ppu)

    ppu =
      [{0x28, 0x00}, {0x29, 0x30}, {0x2A, 0x00}, {0x2B, 0x00}]
      |> Enum.reduce(ppu, fn {offset, value}, ppu ->
        PPU.put_affine_register(ppu, offset, value)
      end)
      |> PPU.begin_next_line(<<>>, <<>>, <<>>)

    assert elem(ppu.scanline_bg_affine, 3) |> elem(0) ==
             {0x0100, 0x0100, 0, 0x0200, 0x3000, 0x2400}
  end
end
