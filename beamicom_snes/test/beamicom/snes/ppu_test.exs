defmodule Beamicom.SNES.PPUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.PPU

  test "writes VRAM words with configurable increment timing" do
    ppu =
      PPU.new()
      |> PPU.write(0x2115, 0x80)
      |> PPU.write(0x2116, 0x00)
      |> PPU.write(0x2117, 0x00)
      |> PPU.write(0x2118, 0xAA)

    assert ppu.vmadd == 0
    ppu = PPU.write(ppu, 0x2119, 0xBB)
    assert ppu.vmadd == 1

    ppu = ppu |> PPU.write(0x2116, 0) |> PPU.write(0x2117, 0)
    assert {0xAA, ppu} = PPU.read(ppu, 0x2139, 0)
    assert ppu.vmadd == 0
    assert {0xBB, ppu} = PPU.read(ppu, 0x213A, 0)
    assert ppu.vmadd == 1
  end

  test "renders a Mode 1 planar BG tile to native RGB24" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> write_vram_byte(0x0000, 0x80)
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x00)
      |> PPU.write(0x2121, 1)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0x00)

    frame = PPU.render_frame(ppu)
    assert frame.width == 256
    assert frame.height == 224
    assert byte_size(frame.data) == 256 * 224 * 3
    assert binary_part(frame.data, 0, 6) == <<255, 0, 0, 0, 0, 0>>
  end

  test "forced blank takes the allocation-light solid-frame path" do
    frame = PPU.render_frame(PPU.new())
    assert frame.data == :binary.copy(<<0, 0, 0>>, 256 * 224)
  end

  test "exposes the signed Mode 7 multiplication result" do
    ppu =
      PPU.new()
      |> PPU.write(0x211B, 0x34)
      |> PPU.write(0x211B, 0x12)
      |> PPU.write(0x211C, 0x00)
      |> PPU.write(0x211C, 0xFE)

    product = 0x1234 * -2 &&& 0xFFFFFF
    low = product &&& 0xFF
    middle = product >>> 8 &&& 0xFF
    high = product >>> 16 &&& 0xFF
    assert {^low, ppu} = PPU.read(ppu, 0x2134, 0)
    assert {^middle, ppu} = PPU.read(ppu, 0x2135, 0)
    assert {^high, _ppu} = PPU.read(ppu, 0x2136, 0)
  end

  test "reuses unchanged frames and invalidates the cache on visual changes" do
    ppu = PPU.new() |> PPU.write(0x2100, 0x0F) |> PPU.enter_scanline(225)
    {first, ppu} = PPU.take_frame(ppu)
    assert ppu.rendered_frames == 1

    ppu = PPU.enter_scanline(ppu, 225)
    {second, ppu} = PPU.take_frame(ppu)
    assert second.data == first.data
    assert ppu.rendered_frames == 1
    assert ppu.reused_frames == 1

    ppu = ppu |> PPU.write(0x2100, 0x0E) |> PPU.enter_scanline(225)
    assert ppu.rendered_frames == 2
  end

  defp write_vram_byte(ppu, byte_address, value) do
    word_address = div(byte_address, 2)
    high? = rem(byte_address, 2) == 1

    ppu
    |> PPU.write(0x2115, if(high?, do: 0x00, else: 0x80))
    |> PPU.write(0x2116, word_address &&& 0xFF)
    |> PPU.write(0x2117, word_address >>> 8)
    |> PPU.write(if(high?, do: 0x2119, else: 0x2118), value)
  end
end
