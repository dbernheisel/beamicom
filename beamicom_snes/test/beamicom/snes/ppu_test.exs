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

  test "MOSAIC repeats each enabled background's upper-left pixel in screen-aligned blocks" do
    base =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x2108, 0x08)
      # BG1 and BG2 use separate copies of the same test tile.
      |> PPU.write(0x210B, 0x10)
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x00)
      |> write_vram_byte(0x1000, 0x00)
      |> write_vram_byte(0x1001, 0x00)
      # Row 0 begins with palette colors 1, 2; row 1 begins with color 3.
      |> write_vram_byte(0x0000, 0x80)
      |> write_vram_byte(0x0001, 0x40)
      |> write_vram_byte(0x0002, 0x80)
      |> write_vram_byte(0x0003, 0x80)
      |> write_vram_byte(0x2000, 0x80)
      |> write_vram_byte(0x2001, 0x40)
      |> write_vram_byte(0x2002, 0x80)
      |> write_vram_byte(0x2003, 0x80)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(2, 0x7C00)
      |> write_cgram_color(3, 0x03E0)

    # Size nibble 1 means 2x2. Enabling BG1 repeats horizontally and vertically.
    bg1 = base |> PPU.write(0x212C, 0x01) |> PPU.write(0x2106, 0x11)
    assert bg1.mosaic == 0x11
    frame = PPU.render_frame(bg1)
    assert binary_part(frame.data, 0, 6) == <<255, 0, 0, 255, 0, 0>>
    assert binary_part(frame.data, 256 * 3, 6) == <<255, 0, 0, 255, 0, 0>>

    # BG1's enable bit must not affect BG2; BG2's own bit enables the same effect.
    bg2 = base |> PPU.write(0x212C, 0x02) |> PPU.write(0x2106, 0x11)
    assert binary_part(PPU.render_frame(bg2).data, 0, 6) == <<255, 0, 0, 0, 0, 255>>

    bg2 = PPU.write(bg2, 0x2106, 0x12)
    assert binary_part(PPU.render_frame(bg2).data, 0, 6) == <<255, 0, 0, 255, 0, 0>>
  end

  test "Mode 7 EXTBG uses BG1's mosaic bit vertically and BG2's horizontally" do
    base =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x07)
      |> PPU.write(0x2133, 0x40)
      |> PPU.write(0x212C, 0x01)
      # Identity transform. The first output row samples Mode 7 texture row 1.
      |> PPU.write(0x211B, 0x00)
      |> PPU.write(0x211B, 0x01)
      |> PPU.write(0x211E, 0x00)
      |> PPU.write(0x211E, 0x01)
      |> write_vram_byte(0x0000, 0x01)
      |> write_vram_byte(0x0091, 0x01)
      |> write_vram_byte(0x0093, 0x02)
      |> write_vram_byte(0x00A1, 0x03)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(2, 0x7C00)
      |> write_cgram_color(3, 0x03E0)

    horizontal = PPU.write(base, 0x2106, 0x12)
    assert binary_part(PPU.render_frame(horizontal).data, 0, 6) == <<255, 0, 0, 255, 0, 0>>

    vertical = PPU.write(base, 0x2106, 0x11)
    frame = PPU.render_frame(vertical)
    assert binary_part(frame.data, 0, 6) == <<255, 0, 0, 0, 0, 255>>
    assert binary_part(frame.data, 256 * 3, 3) == <<255, 0, 0>>
  end

  test "keeps tile color zero transparent with a nonzero palette base" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x2108, 0x08)
      |> PPU.write(0x210B, 0x10)
      |> PPU.write(0x212C, 0x03)
      # BG1 tile 0, palette 1, high priority; its raw color remains zero.
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x24)
      # BG2 tile 0 has raw color 1 at x=0.
      |> write_vram_byte(0x1000, 0x00)
      |> write_vram_byte(0x1001, 0x00)
      |> write_vram_byte(0x2000, 0x80)
      |> PPU.write(0x2121, 1)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0x00)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 3) == <<255, 0, 0>>
  end

  test "uses CGADSUB bit 7 for subtraction and bit 6 for halving" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2108, 0x08)
      |> PPU.write(0x2109, 0x0C)
      |> PPU.write(0x210B, 0x10)
      |> PPU.write(0x210C, 0x02)
      |> PPU.write(0x212C, 0x02)
      |> PPU.write(0x212D, 0x04)
      |> PPU.write(0x2130, 0x02)
      # Add BG2 and halve the result.
      |> PPU.write(0x2131, 0x42)
      |> write_vram_byte(0x1000, 0x00)
      |> write_vram_byte(0x1001, 0x00)
      |> write_vram_byte(0x1800, 0x00)
      |> write_vram_byte(0x1801, 0x04)
      |> write_vram_byte(0x2000, 0x80)
      |> write_vram_byte(0x4000, 0x80)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(5, 0x7C00)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 3) == <<123, 0, 123>>
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

  test "OAM ports use word addresses, latch low-table pairs, and mirror the high table" do
    ppu =
      PPU.new()
      |> PPU.write(0x2102, 1)
      |> PPU.write(0x2103, 0)
      |> PPU.write(0x2104, 0x12)

    assert :array.get(2, ppu.oam) == 0
    assert ppu.oam_internal_address == 3

    ppu = PPU.write(ppu, 0x2104, 0x34)
    assert :array.get(2, ppu.oam) == 0x12
    assert :array.get(3, ppu.oam) == 0x34
    assert ppu.oam_internal_address == 4

    ppu =
      ppu
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 1)
      |> PPU.write(0x2104, 0x56)

    assert :array.get(512, ppu.oam) == 0x56

    ppu = Enum.reduce(1..32, ppu, fn value, ppu -> PPU.write(ppu, 0x2104, value) end)
    assert :array.get(512, ppu.oam) == 32

    ppu = ppu |> PPU.write(0x2102, 1) |> PPU.write(0x2103, 0)
    assert {0x12, ppu} = PPU.read(ppu, 0x2138, 0)
    assert {0x34, _ppu} = PPU.read(ppu, 0x2138, 0)
  end

  test "OAM priority rotation changes the first sprite in overlap order" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x212C, 0x10)
      |> write_vram_byte(0x0000, 0x80)
      |> write_vram_byte(0x0020, 0x80)
      |> write_cgram_color(129, 0x001F)
      |> write_cgram_color(145, 0x03E0)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0)

    # Sprite 0 uses tile 0/palette 0; sprite 1 uses tile 1/palette 1.
    ppu =
      Enum.reduce([0, 0, 0, 0, 0, 0, 1, 2], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)

    assert binary_part(PPU.render_frame(ppu).data, 0, 3) == <<255, 0, 0>>

    rotated = ppu |> PPU.write(0x2102, 2) |> PPU.write(0x2103, 0x80)
    assert rotated.obj_first == 1
    assert binary_part(PPU.render_frame(rotated).data, 0, 3) == <<0, 255, 0>>
  end

  test "scanline capture preserves mid-frame OAM priority rotation" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x212C, 0x10)
      |> write_vram_byte(0x0000, 0xC0)
      |> write_vram_byte(0x0002, 0xC0)
      |> write_vram_byte(0x0020, 0xC0)
      |> write_vram_byte(0x0022, 0xC0)
      |> write_cgram_color(129, 0x001F)
      |> write_cgram_color(145, 0x03E0)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0)

    ppu =
      Enum.reduce([0, 0, 0, 0, 0, 0, 1, 2], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)

    ppu = ppu |> PPU.begin_frame(true) |> PPU.capture_scanline(1)
    ppu = ppu |> PPU.write(0x2102, 2) |> PPU.write(0x2103, 0x80)
    ppu = Enum.reduce(2..224, ppu, fn line, ppu -> PPU.capture_scanline(ppu, line) end)
    data = PPU.render_frame(ppu).data

    assert binary_part(data, 0, 3) == <<255, 0, 0>>
    assert binary_part(data, 256 * 3, 3) == <<0, 255, 0>>
  end

  test "renders Mode 7's interleaved tilemap and pixel data" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x07)
      |> PPU.write(0x212C, 0x01)
      # Identity horizontal matrix. All rows use texture Y=0 here.
      |> PPU.write(0x211B, 0x00)
      |> PPU.write(0x211B, 0x01)
      # Tilemap (low VRAM byte) selects tile 1 at the origin.
      |> write_vram_byte(0x0000, 0x01)
      # Mode 7 pixels occupy high VRAM bytes, packed one byte per pixel.
      |> write_vram_byte(0x0081, 0x01)
      |> write_cgram_color(1, 0x001F)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 6) == <<255, 0, 0, 0, 0, 0>>
  end

  test "renders an 8bpp Mode 3 background tile" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x03)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      # BG1 tilemap selects tile zero. Plane 6 gives the first pixel index 64.
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x00)
      |> write_vram_byte(0x0030, 0x80)
      |> write_cgram_color(64, 0x03E0)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 6) == <<0, 255, 0, 0, 0, 0>>
  end

  test "Mode 3 direct color combines 8bpp pixels with tile palette bits" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x03)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x2130, 0x01)
      # Tile palette 1 supplies the low red component bit in direct-color mode.
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x04)
      |> write_vram_byte(0x0000, 0x80)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 3) == <<49, 0, 0>>
  end

  test "all legal background modes render without a missing layer definition" do
    for mode <- 0..7 do
      ppu =
        PPU.new()
        |> PPU.write(0x2100, 0x0F)
        |> PPU.write(0x2105, mode)
        |> PPU.write(0x212C, 0x1F)

      assert %{data: data} = PPU.render_frame(ppu)
      assert byte_size(data) == 256 * 224 * 3
    end
  end

  test "Nx Mode 7 rendering is pixel-exact with the native renderer" do
    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      ppu =
        PPU.new()
        |> PPU.write(0x2100, 0x0F)
        |> PPU.write(0x2105, 0x07)
        |> PPU.write(0x212C, 0x01)
        |> PPU.write(0x211B, 0x00)
        |> PPU.write(0x211B, 0x01)
        |> write_vram_byte(0x0000, 0x01)
        |> write_vram_byte(0x0081, 0x01)
        |> write_cgram_color(1, 0x001F)

      native = PPU.render_frame(ppu).data
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      nx = Beamicom.SNES.Nx.PPURenderer.render(ppu, objects)
      assert nx == native
    end
  end

  test "Mode 7 EXTBG uses bit 7 as BG2 priority instead of a palette bit" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x07)
      |> PPU.write(0x2133, 0x40)
      |> PPU.write(0x212C, 0x02)
      |> PPU.write(0x211B, 0x00)
      |> PPU.write(0x211B, 0x01)
      |> write_vram_byte(0x0000, 0x01)
      |> write_vram_byte(0x0081, 0x81)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(129, 0x7C00)

    assert ppu.extbg?
    native = PPU.render_frame(ppu).data
    assert binary_part(native, 0, 3) == <<255, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == native
    end
  end

  test "Nx Mode 7 EXTBG priority pixels straddle priority-1 OBJ" do
    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      ppu =
        PPU.new()
        |> PPU.write(0x2100, 0x0F)
        |> PPU.write(0x2105, 0x07)
        |> PPU.write(0x2133, 0x40)
        |> PPU.write(0x212C, 0x12)
        |> PPU.write(0x211B, 0x00)
        |> PPU.write(0x211B, 0x01)
        |> write_vram_byte(0x0000, 0x01)
        |> write_vram_byte(0x0081, 0x81)
        |> write_cgram_color(1, 0x001F)
        |> write_cgram_color(129, 0x03E0)

      objects = <<129, 2>> <> :binary.copy(<<0, 0>>, 256 * 224 - 1)
      high = Beamicom.SNES.Nx.PPURenderer.render(ppu, objects)
      assert binary_part(high, 0, 3) == <<255, 0, 0>>

      low =
        ppu
        |> write_vram_byte(0x0081, 0x01)
        |> Beamicom.SNES.Nx.PPURenderer.render(objects)

      assert binary_part(low, 0, 3) == <<0, 255, 0>>
    end
  end

  test "Nx resident VRAM is isolated between PPU instances" do
    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      build_ppu = fn pixel ->
        PPU.new()
        |> PPU.write(0x2100, 0x0F)
        |> PPU.write(0x2105, 0x07)
        |> PPU.write(0x212C, 0x01)
        |> PPU.write(0x211B, 0x00)
        |> PPU.write(0x211B, 0x01)
        |> write_vram_byte(0x0000, 0x01)
        |> write_vram_byte(0x0081, pixel)
        |> write_cgram_color(1, 0x001F)
        |> write_cgram_color(2, 0x7C00)
      end

      objects = :binary.copy(<<0, 0>>, 256 * 224)
      red = Beamicom.SNES.Nx.PPURenderer.render(build_ppu.(1), objects)
      blue = Beamicom.SNES.Nx.PPURenderer.render(build_ppu.(2), objects)

      assert binary_part(red, 0, 3) == <<255, 0, 0>>
      assert binary_part(blue, 0, 3) == <<0, 0, 255>>
    end
  end

  test "latches all Mode 7 transform registers through their shared byte latch" do
    ppu =
      PPU.new()
      |> PPU.write(0x211A, 0xC3)
      |> PPU.write(0x210D, 0x34)
      |> PPU.write(0x210D, 0x12)
      |> PPU.write(0x210E, 0x78)
      |> PPU.write(0x210E, 0x56)
      |> PPU.write(0x211D, 0xBC)
      |> PPU.write(0x211D, 0x9A)
      |> PPU.write(0x211E, 0xF0)
      |> PPU.write(0x211E, 0xDE)
      |> PPU.write(0x211F, 0x57)
      |> PPU.write(0x211F, 0x13)
      |> PPU.write(0x2120, 0x68)
      |> PPU.write(0x2120, 0x24)

    assert {ppu.m7sel, ppu.m7hofs, ppu.m7vofs} == {0xC3, 0x1234, 0x5678}
    assert {ppu.m7c, ppu.m7d, ppu.m7x, ppu.m7y} == {0x9ABC, 0xDEF0, 0x1357, 0x2468}
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

  defp write_cgram_color(ppu, index, color) do
    ppu
    |> PPU.write(0x2121, index)
    |> PPU.write(0x2122, color &&& 0xFF)
    |> PPU.write(0x2122, color >>> 8)
  end
end
