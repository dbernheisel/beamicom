defmodule Beamicom.SNES.PPUTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.SNES.PPU

  test "preserves every low horizontal scroll bit across the two writes" do
    ppu =
      PPU.new()
      |> PPU.write(0x210D, 0x04)
      |> PPU.write(0x210D, 0x00)

    assert elem(ppu.bg_hofs, 0) == 4

    ppu =
      ppu
      |> PPU.write(0x210D, 0x05)
      |> PPU.write(0x210D, 0x01)

    assert elem(ppu.bg_hofs, 0) == 0x105
  end

  test "keeps the horizontal and shared scroll latches separate" do
    ppu =
      PPU.new()
      |> PPU.write(0x210D, 0x04)
      |> PPU.write(0x210E, 0xAA)
      |> PPU.write(0x210E, 0x00)
      |> PPU.write(0x210D, 0x01)

    assert elem(ppu.bg_hofs, 0) == 0x104
  end

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

  test "buffers VRAM reads and reloads before incrementing on low-byte reads" do
    ppu =
      PPU.new()
      |> write_vram_byte(0x0000, 0x11)
      |> write_vram_byte(0x0001, 0x22)
      |> write_vram_byte(0x0002, 0x33)
      |> write_vram_byte(0x0003, 0x44)
      |> PPU.write(0x2115, 0x00)
      |> PPU.write(0x2116, 0x00)
      |> PPU.write(0x2117, 0x00)

    assert {0x11, ppu} = PPU.read(ppu, 0x2139, 0)
    assert ppu.vmadd == 1
    assert {0x11, ppu} = PPU.read(ppu, 0x2139, 0)
    assert ppu.vmadd == 2
    assert {0x33, ppu} = PPU.read(ppu, 0x2139, 0)
    assert ppu.vmadd == 3
  end

  test "buffers VRAM reads and reloads before incrementing on high-byte reads" do
    ppu =
      PPU.new()
      |> write_vram_byte(0x0000, 0x11)
      |> write_vram_byte(0x0001, 0x22)
      |> write_vram_byte(0x0002, 0x33)
      |> write_vram_byte(0x0003, 0x44)
      |> PPU.write(0x2115, 0x80)
      |> PPU.write(0x2116, 0x00)
      |> PPU.write(0x2117, 0x00)

    assert {0x22, ppu} = PPU.read(ppu, 0x213A, 0)
    assert ppu.vmadd == 1
    assert {0x22, ppu} = PPU.read(ppu, 0x213A, 0)
    assert ppu.vmadd == 2
    assert {0x44, ppu} = PPU.read(ppu, 0x213A, 0)
    assert ppu.vmadd == 3
  end

  test "writes and reads CGRAM through a shared two-byte phase" do
    ppu =
      PPU.new()
      |> PPU.write(0x2121, 0x12)
      |> PPU.write(0x2122, 0xCD)
      |> PPU.write(0x2122, 0xAB)
      |> PPU.write(0x2121, 0x12)

    assert {0xCD, ppu} = PPU.read(ppu, 0x213B, 0)
    assert ppu.cgadd == 0x12
    assert ppu.cgram_second_byte?

    assert {0xAB, ppu} = PPU.read(ppu, 0x213B, 0xCD)
    assert ppu.cgadd == 0x13
    refute ppu.cgram_second_byte?
  end

  test "keeps the CGRAM write latch intact when a read supplies the low-byte phase" do
    ppu =
      PPU.new()
      |> PPU.write(0x2121, 0)
      |> PPU.write(0x2122, 0x34)
      |> PPU.write(0x2122, 0x12)
      |> PPU.write(0x2121, 1)

    assert {0, ppu} = PPU.read(ppu, 0x213B, 0)
    assert ppu.cgram_second_byte?

    ppu = PPU.write(ppu, 0x2122, 0x56)
    assert :array.get(1, ppu.cgram) == 0x5634
    assert ppu.cgadd == 2
    refute ppu.cgram_second_byte?
  end

  test "renders a Mode 1 planar BG tile to native RGB24" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> write_vram_byte(0x0002, 0x80)
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

  test "the hidden first hardware scanline advances the visible BG source row" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> write_vram_byte(0x0000, 0x80)
      |> write_vram_byte(0x0003, 0x80)
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x00)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(2, 0x7C00)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 0) == <<0, 0, 255>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == frame.data
    end
  end

  test "applies master brightness in 5-bit space before DAC expansion" do
    full =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> write_cgram_color(0, 0x021F)

    # Bit replication maps the mid-range green component 16 to 132.  A direct
    # 5-bit-to-255 ratio would incorrectly round it down to 131.
    assert binary_part(PPU.render_frame(full).data, 0, 3) == <<255, 132, 0>>

    half =
      PPU.new()
      |> PPU.write(0x2100, 0x07)
      |> PPU.write(0x2105, 0x01)
      |> write_cgram_color(0, 0x001F)

    # Brightness is applied before expansion: floor(31 * 7 / 15) = 14,
    # and (14 << 3) | (14 >> 2) = 115.
    assert binary_part(PPU.render_frame(half).data, 0, 3) == <<115, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(full, objects) == PPU.render_frame(full).data
      assert Beamicom.SNES.Nx.PPURenderer.render(half, objects) == PPU.render_frame(half).data
    end
  end

  test "MOSAIC repeats each enabled background's upper-left pixel in screen-aligned blocks" do
    base = mosaic_test_ppu()

    # Size nibble 1 means 2x2. Enabling BG1 repeats horizontally and vertically.
    bg1 = base |> PPU.write(0x212C, 0x01) |> PPU.write(0x2106, 0x11)
    assert bg1.mosaic == 0x11
    frame = PPU.render_frame(bg1)
    assert binary_part(frame.data, 0, 6) == <<0, 255, 0, 0, 255, 0>>
    assert binary_part(frame.data, 256 * 3, 6) == <<0, 255, 0, 0, 255, 0>>

    # BG1's enable bit must not affect BG2; BG2's own bit enables the same effect.
    bg2 = base |> PPU.write(0x212C, 0x02) |> PPU.write(0x2106, 0x11)
    assert binary_part(PPU.render_frame(bg2).data, 0, 6) == <<0, 255, 0, 0, 0, 0>>

    bg2 = PPU.write(bg2, 0x2106, 0x12)
    assert binary_part(PPU.render_frame(bg2).data, 0, 6) == <<0, 255, 0, 0, 255, 0>>
  end

  test "MOSAIC vertical phase starts at the first visible scanline each frame" do
    ppu =
      mosaic_test_ppu()
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x2106, 0x11)
      |> PPU.begin_frame(true)
      |> capture_frame_scanlines()

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 0) == <<0, 255, 0>>
    assert pixel_at(frame.data, 0, 1) == <<0, 255, 0>>
  end

  test "enabling MOSAIC mid-frame starts a new vertical block" do
    ppu =
      mosaic_test_ppu()
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x2106, 0x10)
      |> PPU.begin_frame(true)
      |> PPU.capture_scanline(1)
      |> PPU.write(0x2106, 0x11)
      |> capture_scanlines(2..224)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 0) == <<0, 255, 0>>
    assert pixel_at(frame.data, 0, 1) == <<0, 0, 255>>
    assert pixel_at(frame.data, 0, 2) == <<0, 0, 255>>
  end

  test "changing MOSAIC size mid-frame reloads its vertical phase" do
    ppu =
      mosaic_test_ppu()
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x2106, 0x11)
      |> PPU.begin_frame(true)
      |> PPU.capture_scanline(1)
      |> PPU.write(0x2106, 0x21)
      |> capture_scanlines(2..224)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 1) == <<0, 0, 255>>
    assert pixel_at(frame.data, 0, 2) == <<0, 0, 255>>
    assert pixel_at(frame.data, 0, 3) == <<0, 0, 255>>
  end

  test "writing an unchanged MOSAIC value does not reload its vertical phase" do
    ppu =
      mosaic_test_ppu()
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x2106, 0x11)
      |> PPU.begin_frame(true)
      |> PPU.capture_scanline(1)
      |> PPU.write(0x2106, 0x11)
      |> capture_scanlines(2..224)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 1) == <<0, 255, 0>>
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
      |> write_vram_byte(0x2002, 0x80)
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
      |> write_vram_byte(0x2002, 0x80)
      |> write_vram_byte(0x4002, 0x80)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(5, 0x7C00)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 3) == <<123, 0, 123>>
  end

  test "halves color addition before saturating each component" do
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
      |> PPU.write(0x2131, 0x42)
      |> write_vram_byte(0x1000, 0x00)
      |> write_vram_byte(0x1001, 0x00)
      |> write_vram_byte(0x1800, 0x00)
      |> write_vram_byte(0x1801, 0x04)
      |> write_vram_byte(0x2002, 0x80)
      |> write_vram_byte(0x4002, 0x80)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(5, 0x001F)

    native = PPU.render_frame(ppu).data
    assert binary_part(native, 0, 3) == <<255, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == native
    end
  end

  test "uses unhalved fixed color when the selected sub-screen is uncovered" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x212D, 0x00)
      |> PPU.write(0x2130, 0x02)
      # Add and halve BG1, if a real sub-screen pixel covers this dot.
      |> PPU.write(0x2131, 0x41)
      # Green COLDATA fallback.
      |> PPU.write(0x2132, 0x5F)
      |> write_vram_byte(0x0800, 0x00)
      |> write_vram_byte(0x0801, 0x00)
      |> write_vram_byte(0x0002, 0x80)
      |> write_cgram_color(1, 0x001F)

    # An empty sub screen falls back to fixed green and disables halving, so
    # the full-red main pixel becomes full yellow.
    native = PPU.render_frame(ppu).data
    assert binary_part(native, 0, 3) == <<255, 255, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == native
    end
  end

  test "ignores color-window selection when clip and prevent modes are disabled" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> write_cgram_color(0, 0x001F)

    baseline = PPU.render_frame(ppu)
    configured = ppu |> PPU.write(0x2125, 0xB0) |> PPU.render_frame()

    assert binary_part(baseline.data, 0, 3) == <<255, 0, 0>>
    assert configured.data == baseline.data
  end

  test "clips the main screen to black while color math is disabled" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2125, 0x20)
      |> PPU.write(0x2126, 0)
      |> PPU.write(0x2127, 127)
      |> PPU.write(0x2130, 0x80)
      |> write_cgram_color(0, 0x001F)

    for ppu <- [ppu, PPU.write(ppu, 0x212E, 0x01)] do
      native = PPU.render_frame(ppu).data

      assert binary_part(native, 0, 3) == <<0, 0, 0>>
      assert binary_part(native, 200 * 3, 3) == <<255, 0, 0>>

      if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
        objects = :binary.copy(<<0, 0>>, 256 * 224)
        assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == native
      end
    end
  end

  test "decodes window selector pairs as enable then invert" do
    base =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x212E, 0x01)
      |> PPU.write(0x2126, 0)
      |> PPU.write(0x2127, 127)
      |> write_vram_byte(0x0002, 0xFF)
      |> write_cgram_color(1, 0x001F)

    # W12SEL's BG1 low pair is EI: bit 1 enables window 1 and bit 0
    # inverts it. With %10, BG1 is masked inside x=0..127.
    inside = PPU.write(base, 0x2123, 0x02)
    native = PPU.render_frame(inside).data
    assert binary_part(native, 0, 3) == <<0, 0, 0>>
    assert binary_part(native, 200 * 3, 3) == <<255, 0, 0>>

    # Setting the low invert bit reverses the masked area.
    inverted = PPU.render_frame(PPU.write(base, 0x2123, 0x03)).data
    assert binary_part(inverted, 0, 3) == <<255, 0, 0>>
    assert binary_part(inverted, 200 * 3, 3) == <<0, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(inside, objects) == native
    end
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

  test "OAM writes advance the priority-rotation first sprite" do
    ppu =
      PPU.new()
      |> PPU.write(0x2102, 0xFF)
      |> PPU.write(0x2103, 0x80)

    assert ppu.oam_internal_address == 0x1FE
    assert ppu.obj_first == 0x7F

    ppu = PPU.write(ppu, 0x2104, 0x12)
    assert ppu.oam_internal_address == 0x1FF
    assert ppu.obj_first == 0x7F

    ppu = PPU.write(ppu, 0x2104, 0x34)
    assert ppu.oam_internal_address == 0x200
    assert ppu.obj_first == 0
  end

  test "OAM reads advance the priority-rotation first sprite" do
    ppu =
      PPU.new()
      |> PPU.write(0x2102, 1)
      |> PPU.write(0x2103, 0x80)

    assert ppu.oam_internal_address == 2
    assert ppu.obj_first == 0

    assert {_value, ppu} = PPU.read(ppu, 0x2138, 0)
    assert ppu.oam_internal_address == 3
    assert ppu.obj_first == 0

    assert {_value, ppu} = PPU.read(ppu, 0x2138, 0)
    assert ppu.oam_internal_address == 4
    assert ppu.obj_first == 1
  end

  test "vblank restores the priority-rotation first sprite with the OAM address" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0x80)
      |> PPU.write(0x2104, 0)
      |> PPU.write(0x2104, 0)
      |> PPU.write(0x2104, 0)
      |> PPU.write(0x2104, 0)

    assert ppu.oam_internal_address == 4
    assert ppu.obj_first == 1

    ppu = PPU.enter_scanline(ppu, 225)
    assert ppu.oam_internal_address == 0
    assert ppu.obj_first == 0
  end

  test "large OBJ horizontal tiles wrap within the character row" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      # Size pair 2 makes a high-table-sized object 64x64.
      |> PPU.write(0x2101, 0x40)
      |> PPU.write(0x212C, 0x10)
      # The second tile after character $0f is $00, not $10.
      |> write_vram_byte(0x0000, 0x80)
      |> write_cgram_color(129, 0x001F)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0)

    ppu =
      Enum.reduce([0, 0, 0x0F, 0], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)

    ppu =
      ppu
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 1)
      |> PPU.write(0x2104, 0x02)

    assert binary_part(PPU.render_frame(ppu).data, 8 * 3, 3) == <<255, 0, 0>>
  end

  test "OBJSEL size mode 6 renders 16x32 and 32x64 objects" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2101, 0xC0)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x212C, 0x10)
      # Small OBJ bottom-right: tile column 1, tile row 3, pixel 7 on row 7.
      |> write_vram_byte(0x31 * 32 + 7 * 2, 0x01)
      # Large OBJ bottom-right: tile column 3, tile row 7, pixel 7 on row 7.
      |> write_vram_byte(0x73 * 32 + 7 * 2, 0x01)
      |> write_cgram_color(129, 0x001F)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0)

    ppu =
      Enum.reduce([0, 0, 0, 0, 32, 0, 0, 0], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)

    # Sprite 1 is large; sprite 0 remains small.
    ppu =
      ppu
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 1)
      |> PPU.write(0x2104, 0x08)

    previous = Application.get_env(:beamicom_snes, :ppu_renderer, :native)
    on_exit(fn -> Application.put_env(:beamicom_snes, :ppu_renderer, previous) end)
    Application.put_env(:beamicom_snes, :ppu_renderer, :native)

    native = PPU.render_frame(ppu).data
    assert pixel_at(native, 15, 31) == <<255, 0, 0>>
    assert pixel_at(native, 16, 31) == <<0, 0, 0>>
    assert pixel_at(native, 15, 32) == <<0, 0, 0>>
    assert pixel_at(native, 63, 63) == <<255, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      Application.put_env(:beamicom_snes, :ppu_renderer, :nx)
      assert PPU.render_frame(ppu).data == native
    end
  end

  test "OBJSEL size mode 7 flips a 16x32 object across both dimensions" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2101, 0xE0)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x212C, 0x10)
      # Source bottom-right becomes output top-left under horizontal and vertical flip.
      |> write_vram_byte(0x31 * 32 + 7 * 2, 0x01)
      |> write_cgram_color(129, 0x001F)
      |> PPU.write(0x2102, 0)
      |> PPU.write(0x2103, 0)

    ppu =
      Enum.reduce([24, 8, 0, 0xC0], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)

    previous = Application.get_env(:beamicom_snes, :ppu_renderer, :native)
    on_exit(fn -> Application.put_env(:beamicom_snes, :ppu_renderer, previous) end)
    Application.put_env(:beamicom_snes, :ppu_renderer, :native)

    native = PPU.render_frame(ppu).data
    assert pixel_at(native, 24, 8) == <<255, 0, 0>>
    assert pixel_at(native, 25, 8) == <<0, 0, 0>>
    assert pixel_at(native, 24, 40) == <<0, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      Application.put_env(:beamicom_snes, :ppu_renderer, :nx)
      assert PPU.render_frame(ppu).data == native
    end
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
    test "Nx PPU rasterizes OBJ descriptors with native pixel parity" do
      previous = Application.get_env(:beamicom_snes, :ppu_renderer, :native)
      on_exit(fn -> Application.put_env(:beamicom_snes, :ppu_renderer, previous) end)

      ppu =
        PPU.new()
        |> PPU.write(0x2100, 0x0F)
        |> PPU.write(0x2105, 0x01)
        |> PPU.write(0x212C, 0x10)
        |> write_vram_byte(0x0000, 0x81)
        |> write_vram_byte(0x0010, 0x01)
        |> write_cgram_color(129, 0x001F)
        |> PPU.write(0x2102, 0)
        |> PPU.write(0x2103, 0)

      ppu =
        Enum.reduce([3, 4, 0, 0x60], ppu, fn byte, ppu ->
          PPU.write(ppu, 0x2104, byte)
        end)

      Application.put_env(:beamicom_snes, :ppu_renderer, :native)
      native = PPU.render_frame(ppu).data
      Application.put_env(:beamicom_snes, :ppu_renderer, :nx)

      assert PPU.render_frame(ppu).data == native
      assert :binary.match(native, <<255, 0, 0>>) != :nomatch
    end
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

  test "scanline capture does not blank earlier rows when the frame ends forced blank" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> write_cgram_color(0, 0x001F)
      |> PPU.begin_frame(true)

    ppu = Enum.reduce(1..100, ppu, fn line, ppu -> PPU.capture_scanline(ppu, line) end)
    ppu = PPU.write(ppu, 0x2100, 0x8F)
    ppu = Enum.reduce(101..224, ppu, fn line, ppu -> PPU.capture_scanline(ppu, line) end)
    data = PPU.render_frame(ppu).data

    assert binary_part(data, 0, 3) == <<255, 0, 0>>
    assert binary_part(data, 99 * 256 * 3, 3) == <<255, 0, 0>>
    assert binary_part(data, 100 * 256 * 3, 3) == <<0, 0, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(ppu, objects) == data
    end
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
      |> write_vram_byte(0x0032, 0x80)
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
      |> write_vram_byte(0x0002, 0x80)

    frame = PPU.render_frame(ppu)
    assert binary_part(frame.data, 0, 3) == <<49, 0, 0>>
  end

  test "Mode 5 fetches 512 horizontal pixels through 16x8 map entries" do
    ppu =
      hires_bg_test_ppu(5)
      |> write_vram_word(0x0800, 0)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(1, 2)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(frame.data, 3, 0) == <<255, 0, 0>>
    assert pixel_at(frame.data, 4, 0) == <<0, 0, 255>>

    scrolled = ppu |> PPU.write(0x210D, 4) |> PPU.write(0x210D, 0)
    assert pixel_at(PPU.render_frame(scrolled).data, 0, 0) == <<0, 0, 255>>
  end

  test "Mode 5 selects 16x8 or 16x16 vertical character layout from BGMODE" do
    small =
      hires_bg_test_ppu(5)
      |> write_vram_word(0x0800, 0)
      |> write_vram_word(0x0800 + 32 * 2, 2)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(2, 3)

    assert pixel_at(PPU.render_frame(small).data, 0, 8) == <<0, 255, 0>>

    large =
      hires_bg_test_ppu(0x15)
      |> write_vram_word(0x0800, 0)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(16, 2)

    assert pixel_at(PPU.render_frame(large).data, 0, 8) == <<0, 0, 255>>
  end

  test "Mode 2 applies separate BG3 horizontal and vertical offsets after the first column" do
    horizontal =
      offset_bg_test_ppu(2)
      |> write_vram_word(0x0800 + 3 * 2, 1)
      |> write_vram_word(0x1000, 0x2010)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(1, 2)

    assert pixel_at(PPU.render_frame(horizontal).data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(PPU.render_frame(horizontal).data, 8, 0) == <<0, 0, 255>>

    vertical =
      offset_bg_test_ppu(2)
      |> write_vram_word(0x0800 + (32 + 1) * 2, 1)
      |> write_vram_word(0x1000 + 32 * 2, 0x2008)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(1, 2)

    assert pixel_at(PPU.render_frame(vertical).data, 8, 0) == <<0, 0, 255>>
  end

  test "Mode 4 uses BG3 bit 15 to select a vertical offset" do
    ppu =
      offset_bg_test_ppu(4)
      |> write_vram_word(0x0800 + (32 + 1) * 2, 1)
      |> write_vram_word(0x1000, 0xA008)
      |> write_8bpp_tile_row(0, 1)
      |> write_8bpp_tile_row(1, 2)

    assert pixel_at(PPU.render_frame(ppu).data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(PPU.render_frame(ppu).data, 8, 0) == <<0, 0, 255>>
  end

  test "Mode 6 combines 512-pixel fetches with BG3 offset-per-tile" do
    ppu =
      hires_bg_test_ppu(6)
      |> PPU.write(0x2109, 0x08)
      |> write_vram_word(0x0800 + 2 * 2, 2)
      |> write_vram_word(0x1000, 0x2010)
      |> write_4bpp_tile_row(0, 1)
      |> write_4bpp_tile_row(1, 1)
      |> write_4bpp_tile_row(2, 2)
      |> write_4bpp_tile_row(3, 2)

    frame = PPU.render_frame(ppu)

    assert pixel_at(frame.data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(frame.data, 8, 0) == <<0, 0, 255>>
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

  test "SETINI stores every software-visible display mode bit" do
    ppu = PPU.new() |> PPU.write(0x2133, 0x4F)

    assert ppu.interlace?
    assert ppu.obj_interlace?
    assert ppu.overscan?
    assert ppu.pseudo_hires?
    assert ppu.extbg?
  end

  test "pseudo-hires downsamples each sub/main pair into the 256-pixel frame" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x01)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x2108, 0x08)
      |> PPU.write(0x210B, 0x10)
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x212D, 0x02)
      |> write_vram_byte(0x0800, 0)
      |> write_vram_byte(0x0801, 0)
      |> write_vram_byte(0x1000, 0)
      |> write_vram_byte(0x1001, 0)
      |> write_vram_byte(0x0002, 0x80)
      |> write_vram_byte(0x2003, 0x80)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(2, 0x7C00)

    assert pixel_at(PPU.render_frame(ppu).data, 0, 0) == <<255, 0, 0>>

    pseudo_hires = PPU.write(ppu, 0x2133, 0x08)
    native = PPU.render_frame(pseudo_hires).data
    assert pixel_at(native, 0, 0) == <<127, 0, 127>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      objects = :binary.copy(<<0, 0>>, 256 * 224)
      assert Beamicom.SNES.Nx.PPURenderer.render(pseudo_hires, objects) == native
    end
  end

  test "OBJ interlace selects alternating character rows for each field" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x212C, 0x10)
      |> PPU.write(0x2133, 0x02)
      |> write_vram_byte(0x0000, 0x80)
      |> write_vram_byte(0x0003, 0x80)
      |> write_cgram_color(129, 0x001F)
      |> write_cgram_color(130, 0x7C00)

    even = ppu |> PPU.begin_frame(false, 0) |> PPU.render_frame()
    odd = ppu |> PPU.begin_frame(false, 1) |> PPU.render_frame()

    assert pixel_at(even.data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(odd.data, 0, 0) == <<0, 0, 255>>
    assert {even.width, even.height} == {256, 224}
    assert {odd.width, odd.height} == {256, 224}
  end

  test "Mode 5 interlace selects the background row for the current field" do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2105, 0x05)
      |> PPU.write(0x2107, 0x04)
      |> PPU.write(0x212C, 0x01)
      |> PPU.write(0x212D, 0x01)
      |> PPU.write(0x2133, 0x01)
      |> write_vram_byte(0x0800, 0)
      |> write_vram_byte(0x0801, 0)
      |> write_vram_byte(0x0004, 0xC0)
      |> write_vram_byte(0x0007, 0xC0)
      |> write_cgram_color(1, 0x001F)
      |> write_cgram_color(2, 0x7C00)

    even = ppu |> PPU.begin_frame(false, 0) |> PPU.render_frame()
    odd = ppu |> PPU.begin_frame(false, 1) |> PPU.render_frame()

    assert pixel_at(even.data, 0, 0) == <<255, 0, 0>>
    assert pixel_at(odd.data, 0, 0) == <<0, 0, 255>>
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

  test "render pipeline publishes one immutable frame behind emulation" do
    ppu = PPU.new(render_pipeline: true) |> PPU.write(0x2100, 0x0F)

    ppu = PPU.enter_scanline(ppu, 225)
    assert {nil, ppu} = PPU.take_frame(ppu)
    assert match?({:running, %Beamicom.SNES.DSPTask{}, _key}, ppu.render_task)
    refute_receive {_reference, _result}, 100

    ppu = PPU.enter_scanline(ppu, 225)
    assert {first, ppu} = PPU.take_frame(ppu)
    assert first.number == 0
    assert ppu.rendered_frames == 1

    ppu = PPU.enter_scanline(ppu, 225)
    assert {second, ppu} = PPU.take_frame(ppu)
    assert second.number == 1
    assert second.data == first.data
    assert ppu.reused_frames == 1
  end

  test "render pipeline reuses its worker when consecutive frames are dirty" do
    ppu = PPU.new(render_pipeline: true) |> PPU.write(0x2100, 0x0F)

    ppu = PPU.enter_scanline(ppu, 225)
    assert {:running, first_task, _key} = ppu.render_task
    assert %Beamicom.SNES.DSPTask{reusable?: true} = first_task

    ppu = ppu |> PPU.write(0x2100, 0x0E) |> PPU.enter_scanline(225)
    assert {:running, second_task, _key} = ppu.render_task
    assert second_task.pid == first_task.pid
  end

  test "overlapping render pipelines fall back without blocking the reusable worker" do
    first = PPU.new(render_pipeline: true) |> PPU.write(0x2100, 0x0F)
    second = PPU.new(render_pipeline: true) |> PPU.write(0x2100, 0x0E)

    first = PPU.enter_scanline(first, 225)
    assert {:running, first_task, _key} = first.render_task
    assert first_task.reusable?

    second = PPU.enter_scanline(second, 225)
    assert {:running, second_task, _key} = second.render_task
    refute second_task.reusable?

    first = PPU.enter_scanline(first, 225)
    second = PPU.enter_scanline(second, 225)
    assert {%{data: first_data}, _first} = PPU.take_frame(first)
    assert {%{data: second_data}, _second} = PPU.take_frame(second)
    assert byte_size(first_data) == 256 * 224 * 3
    assert byte_size(second_data) == 256 * 224 * 3
  end

  test "$213E reports and latches PPU1 version and OBJ overflow state" do
    ppu = %{
      PPU.new()
      | ppu1_mdr: 0xFF,
        obj_range_over?: true,
        obj_time_over?: true
    }

    assert {0xD1, ppu} = PPU.read(ppu, 0x213E, 0x00)
    assert ppu.ppu1_mdr == 0xD1
  end

  test "OBJ range-over and time-over accumulate until the next frame" do
    range_over =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.enter_scanline(1)

    assert range_over.obj_range_over?
    refute range_over.obj_time_over?

    oam =
      Enum.reduce(18..127, PPU.new().oam, fn index, oam ->
        :array.set(index * 4 + 1, 100, oam)
      end)

    time_over =
      %{PPU.new() | force_blank?: false, obsel: 3 <<< 5, oam: oam}
      |> PPU.enter_scanline(1)

    refute time_over.obj_range_over?
    assert time_over.obj_time_over?

    reset = PPU.begin_frame(time_over, false)
    refute reset.obj_range_over?
    refute reset.obj_time_over?
  end

  test "PPU1 and PPU2 reads retain distinct data-bus values" do
    ppu = %{PPU.new() | m7_product: 0x5A, latched_hcounter: 0x1AB}

    assert {0x5A, ppu} = PPU.read(ppu, 0x2134, 0x00)
    assert {0xAB, ppu} = PPU.read(ppu, 0x213C, 0x00)

    assert {0x5A, ppu} = PPU.read(ppu, 0x2104, 0xEE)
    assert {0xAB, ppu} = PPU.read(ppu, 0x213C, 0x00)
    assert ppu.ppu1_mdr == 0x5A
    assert ppu.ppu2_mdr == 0xAB
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

  defp write_vram_word(ppu, byte_address, value) do
    ppu
    |> write_vram_byte(byte_address, value &&& 0xFF)
    |> write_vram_byte(byte_address + 1, value >>> 8)
  end

  defp write_4bpp_tile_row(ppu, tile, color) do
    base = tile * 32

    ppu
    |> write_vram_byte(base + 2, if((color &&& 1) != 0, do: 0xFF, else: 0))
    |> write_vram_byte(base + 3, if((color &&& 2) != 0, do: 0xFF, else: 0))
    |> write_vram_byte(base + 18, if((color &&& 4) != 0, do: 0xFF, else: 0))
    |> write_vram_byte(base + 19, if((color &&& 8) != 0, do: 0xFF, else: 0))
  end

  defp write_8bpp_tile_row(ppu, tile, color) do
    base = tile * 64

    Enum.reduce(0..7, ppu, fn plane, ppu ->
      offset = div(plane, 2) * 16 + rem(plane, 2) + 2
      write_vram_byte(ppu, base + offset, if((color &&& 1 <<< plane) != 0, do: 0xFF, else: 0))
    end)
  end

  defp hires_bg_test_ppu(mode) do
    PPU.new()
    |> PPU.write(0x2100, 0x0F)
    |> PPU.write(0x2105, mode)
    |> PPU.write(0x2107, 0x04)
    |> PPU.write(0x212C, 0x01)
    |> PPU.write(0x212D, 0x01)
    |> write_cgram_color(1, 0x001F)
    |> write_cgram_color(2, 0x7C00)
    |> write_cgram_color(3, 0x03E0)
  end

  defp offset_bg_test_ppu(mode) do
    PPU.new()
    |> PPU.write(0x2100, 0x0F)
    |> PPU.write(0x2105, mode)
    |> PPU.write(0x2107, 0x04)
    |> PPU.write(0x2109, 0x08)
    |> PPU.write(0x212C, 0x01)
    |> write_cgram_color(1, 0x001F)
    |> write_cgram_color(2, 0x7C00)
  end

  defp mosaic_test_ppu do
    PPU.new()
    |> PPU.write(0x2100, 0x0F)
    |> PPU.write(0x2105, 0x01)
    |> PPU.write(0x2107, 0x04)
    |> PPU.write(0x2108, 0x08)
    |> PPU.write(0x210B, 0x10)
    |> write_vram_byte(0x0800, 0x00)
    |> write_vram_byte(0x0801, 0x00)
    |> write_vram_byte(0x1000, 0x00)
    |> write_vram_byte(0x1001, 0x00)
    |> write_vram_byte(0x0000, 0x80)
    |> write_vram_byte(0x0001, 0x40)
    |> write_vram_byte(0x0002, 0x80)
    |> write_vram_byte(0x0003, 0x80)
    |> write_vram_byte(0x0005, 0x80)
    |> write_vram_byte(0x2000, 0x80)
    |> write_vram_byte(0x2001, 0x40)
    |> write_vram_byte(0x2002, 0x80)
    |> write_vram_byte(0x2003, 0x80)
    |> write_vram_byte(0x2005, 0x80)
    |> write_cgram_color(1, 0x001F)
    |> write_cgram_color(2, 0x7C00)
    |> write_cgram_color(3, 0x03E0)
  end

  defp capture_frame_scanlines(ppu), do: capture_scanlines(ppu, 1..224)

  defp capture_scanlines(ppu, lines),
    do: Enum.reduce(lines, ppu, fn line, ppu -> PPU.capture_scanline(ppu, line) end)

  defp pixel_at(frame_data, x, y),
    do: binary_part(frame_data, (y * 256 + x) * 3, 3)
end
