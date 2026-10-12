defmodule Beamicom.GBA.BusTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GBA.{APU, Bus, Cartridge, TestROM}
  alias Beamicom.GBA.PPU.ColorCorrection

  @frame_cycles 280_896

  test "maps and mirrors working memory" do
    bus = bus()
    {bus, 3} = Bus.write8(bus, 0x0200_0001, 0xA5)
    {bus, 1} = Bus.write8(bus, 0x0300_0002, 0x5A)

    assert Bus.peek8(bus, 0x0204_0001) == 0xA5
    assert Bus.peek8(bus, 0x0300_8002) == 0x5A
  end

  test "applies GBA byte-write rules and preserves halfword writes" do
    bus = bus()
    {bus, 1} = Bus.write8(bus, 0x0600_0001, 0x22)
    assert Bus.peek16(bus, 0x0600_0000) == 0x2222

    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x1234)
    assert Bus.peek16(bus, 0x0600_0000) == 0x1234

    {bus, 1} = Bus.write8(bus, 0x0700_0000, 0xFF)
    assert Bus.peek8(bus, 0x0700_0000) == 0

    {bus, 1} = Bus.write16(bus, 0x0700_0000, 0xBEEF)
    assert Bus.peek16(bus, 0x0700_0000) == 0xBEEF
  end

  test "rotates unaligned ARM word reads" do
    bus = bus()
    {bus, 1} = Bus.write32(bus, 0x0300_0000, 0x4433_2211)

    assert Bus.peek32(bus, 0x0300_0000) == 0x4433_2211
    assert Bus.peek32(bus, 0x0300_0001) == 0x1144_3322
    assert Bus.peek32(bus, 0x0300_0002) == 0x2211_4433
    assert Bus.peek32(bus, 0x0300_0003) == 0x3322_1144
  end

  test "drives a complete frame from the master-cycle scheduler" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0000, 0x0403)
    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x001F)
    bus = Bus.idle(bus, @frame_cycles - Bus.cycle(bus))

    assert bus.ppu.frame_number == 1
    assert bus.ppu.line == 0
    assert binary_part(bus.ppu.frame, 0, 3) == ColorCorrection.rgb24(0x001F)
    assert byte_size(bus.ppu.frame) == 240 * 160 * 3
  end

  test "VBlank video-memory writes apply to the next display frame" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0000, 0x0403)
    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x001F)
    bus = Bus.idle(bus, 160 * 1_232 - Bus.cycle(bus))

    assert bus.ppu.line == 160

    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x03E0)
    bus = Bus.idle(bus, @frame_cycles - Bus.cycle(bus))

    assert binary_part(bus.ppu.frame, 0, 3) == ColorCorrection.rgb24(0x001F)

    bus = Bus.idle(bus, 2 * @frame_cycles - Bus.cycle(bus))

    assert binary_part(bus.ppu.frame, 0, 3) == ColorCorrection.rgb24(0x03E0)
  end

  test "only treats unobservable display boundaries as safe acceleration windows" do
    bus = bus()
    assert Bus.acceleration_safe?(bus, 960)

    {interrupt_bus, 1} = Bus.write16(bus, 0x0400_0004, 0x0010)
    refute Bus.acceleration_safe?(interrupt_bus, 959)

    last_hblank = Bus.idle(bus, @frame_cycles - 272)
    assert last_hblank.ppu.line == 227
    refute Bus.acceleration_safe?(last_hblank, 272)
  end

  test "maps signed affine background parameters and 28-bit reference points" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0020, 0xFF00)
    {bus, 1} = Bus.write16(bus, 0x0400_0026, 0x0080)
    {bus, 2} = Bus.write32(bus, 0x0400_0028, 0xFABC_DEF0)
    {bus, 2} = Bus.write32(bus, 0x0400_002C, 0x0123_4567)

    assert elem(bus.ppu.bg_affine, 0) ==
             {0xFF00, 0, 0, 0x0080, 0x0ABC_DEF0, 0x0123_4567}

    assert Bus.peek16(bus, 0x0400_0020) == 0xFF00
    assert Bus.peek32(bus, 0x0400_0028) == 0x0ABC_DEF0
  end

  test "maps window, mosaic, and color-effects registers" do
    bus =
      bus()
      |> Bus.put8(0x0400_0040, 0x34)
      |> Bus.put8(0x0400_0041, 0x12)
      |> Bus.put8(0x0400_004C, 0x78)
      |> Bus.put8(0x0400_0055, 0x56)

    assert Bus.peek16(bus, 0x0400_0040) == 0x1234
    assert Bus.peek8(bus, 0x0400_004C) == 0x78
    assert Bus.peek8(bus, 0x0400_0055) == 0x56
    assert elem(bus.ppu.display_effects, 0) == 0x1234
    assert elem(bus.ppu.display_effects, 6) == 0x0078
    assert elem(bus.ppu.display_effects, 10) == 0x5600
  end

  test "encodes keypad buttons as active-low bits" do
    bus = Bus.set_buttons(bus(), [:a, :start, :left, :l])
    assert Bus.peek16(bus, 0x0400_0130) == 0x01D6
  end

  test "maps WAITCNT and applies each Game Pak waitstate" do
    bus = bus()
    {_, bus, 5} = Bus.fetch16(bus, 0x0800_0000, :nonsequential)
    {_, bus, 3} = Bus.fetch16(bus, 0x0800_0002, :sequential)
    {bus, 1} = Bus.write16(bus, 0x0400_0204, 0x07F8)

    assert Bus.peek16(bus, 0x0400_0204) == 0x07F8
    {_, bus, 3} = Bus.fetch16(bus, 0x0800_0000, :nonsequential)
    {_, bus, 2} = Bus.fetch16(bus, 0x0800_0002, :sequential)
    {_, bus, 5} = Bus.fetch32(bus, 0x0800_0000, :nonsequential)
    {_, bus, 4} = Bus.fetch32(bus, 0x0800_0004, :sequential)
    {_, bus, 9} = Bus.fetch16(bus, 0x0A00_0000, :nonsequential)
    {_, bus, 2} = Bus.fetch16(bus, 0x0A00_0002, :sequential)
    {_, _bus, 9} = Bus.fetch16(bus, 0x0C00_0000, :nonsequential)
  end

  test "serves prefetched Game Pak opcodes without wait cycles" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0204, 0x4000)

    {_, bus, 5} = Bus.fetch16(bus, 0x0800_0000, :nonsequential)
    {_, bus, 3} = Bus.fetch16(bus, 0x0800_0002, :sequential)

    bus = Bus.idle(bus, 3)
    {_, _bus, 1} = Bus.fetch16(bus, 0x0800_0004, :sequential)
  end

  test "continues filling the prefetch buffer while consuming a cached opcode" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0204, 0x4000)
    {_, bus, 8} = Bus.fetch32(bus, 0x0800_0000, :nonsequential)
    bus = Bus.idle(bus, 3)

    {_, _bus, 3} = Bus.fetch32(bus, 0x0800_0004, :sequential)
  end

  test "pauses HBlank DMA throughout VBlank" do
    bus = bus()
    {bus, 2} = Bus.write32(bus, 0x0400_00B0, 0x0300_0000)
    {bus, 2} = Bus.write32(bus, 0x0400_00B4, 0x0200_0000)
    {bus, 1} = Bus.write16(bus, 0x0400_00B8, 1)
    {bus, 1} = Bus.write16(bus, 0x0400_00BA, 0xA200)
    bus = Bus.idle(bus, 160 * 1_232 - Bus.cycle(bus))

    assert bus.ppu.line == 160
    source_after_visible_lines = elem(bus.dma, 0).current_source
    assert source_after_visible_lines == 0x0300_0000 + 160 * 2

    bus = Bus.idle(bus, @frame_cycles - Bus.cycle(bus))
    assert bus.ppu.line == 0
    assert elem(bus.dma, 0).current_source == source_after_visible_lines
  end

  test "runs an immediate word DMA transfer" do
    bus = bus()
    {bus, 1} = Bus.write32(bus, 0x0300_0000, 0x1122_3344)
    {bus, 1} = Bus.write32(bus, 0x0300_0004, 0x5566_7788)
    {bus, 2} = Bus.write32(bus, 0x0400_00D4, 0x0300_0000)
    {bus, 2} = Bus.write32(bus, 0x0400_00D8, 0x0200_0000)
    {bus, 1} = Bus.write16(bus, 0x0400_00DC, 2)
    cycle_before_dma = Bus.cycle(bus)
    {bus, 1} = Bus.write16(bus, 0x0400_00DE, 0x8400)

    assert Bus.peek32(bus, 0x0200_0000) == 0x1122_3344
    assert Bus.peek32(bus, 0x0200_0004) == 0x5566_7788
    assert Bus.peek16(bus, 0x0400_00DE) == 0x0400
    assert Bus.cycle(bus) == cycle_before_dma + 17
  end

  test "runs a fixed-source DMA fill through the packed memory path" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0300_0000, 0xCAFE)
    {bus, 2} = Bus.write32(bus, 0x0400_00D4, 0x0300_0000)
    {bus, 2} = Bus.write32(bus, 0x0400_00D8, 0x0200_00FC)
    {bus, 1} = Bus.write16(bus, 0x0400_00DC, 4)
    {bus, 1} = Bus.write16(bus, 0x0400_00DE, 0x8100)

    assert Bus.peek32(bus, 0x0200_00FC) == 0xCAFE_CAFE
    assert Bus.peek32(bus, 0x0200_0100) == 0xCAFE_CAFE
  end

  test "retains sequential DMA overlap behavior" do
    bus = bus()
    {bus, 3} = Bus.write16(bus, 0x0200_0000, 0x1111)
    {bus, 3} = Bus.write16(bus, 0x0200_0002, 0x2222)
    {bus, 3} = Bus.write16(bus, 0x0200_0004, 0x3333)
    {bus, 2} = Bus.write32(bus, 0x0400_00D4, 0x0200_0000)
    {bus, 2} = Bus.write32(bus, 0x0400_00D8, 0x0200_0002)
    {bus, 1} = Bus.write16(bus, 0x0400_00DC, 3)
    {bus, 1} = Bus.write16(bus, 0x0400_00DE, 0x8000)

    assert Bus.peek16(bus, 0x0200_0002) == 0x1111
    assert Bus.peek16(bus, 0x0200_0004) == 0x1111
    assert Bus.peek16(bus, 0x0200_0006) == 0x1111
  end

  test "requests and acknowledges a VBlank interrupt" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0004, 0x0008)
    {bus, 1} = Bus.write16(bus, 0x0400_0200, 0x0001)
    {bus, 1} = Bus.write16(bus, 0x0400_0208, 0x0001)
    bus = Bus.idle(bus, 160 * 1_232 - Bus.cycle(bus))

    assert (Bus.peek16(bus, 0x0400_0004) &&& 1) == 1
    assert Bus.peek16(bus, 0x0400_0202) == 1
    assert Bus.interrupt_pending?(bus)

    {bus, 1} = Bus.write16(bus, 0x0400_0202, 1)
    refute Bus.interrupt_pending?(bus)
  end

  test "refills Direct Sound FIFO A from special-timing DMA1" do
    bus = bus()

    bus =
      Enum.reduce(0..7, bus, fn index, bus ->
        {bus, _cycles} = Bus.write32(bus, 0x0300_0000 + index * 4, 0x0403_0201 + index)
        bus
      end)

    {bus, _cycles} = Bus.write16(bus, 0x0400_0082, 0x0304)
    {bus, _cycles} = Bus.write16(bus, 0x0400_0084, 0x0080)
    {bus, _cycles} = Bus.write32(bus, 0x0400_00BC, 0x0300_0000)
    {bus, _cycles} = Bus.write32(bus, 0x0400_00C0, 0x0400_00A0)
    {bus, _cycles} = Bus.write16(bus, 0x0400_00C4, 0)
    {bus, _cycles} = Bus.write16(bus, 0x0400_00C6, 0xB600)
    {bus, _cycles} = Bus.write16(bus, 0x0400_0100, 0xFF00)
    {bus, _cycles} = Bus.write16(bus, 0x0400_0102, 0x0080)
    cycle_before_refill = Bus.cycle(bus)
    bus = Bus.idle(bus, 300)

    assert APU.fifo_size(bus.apu, :a) == 16
    assert elem(bus.dma, 1).current_source == 0x0300_0010
    assert Bus.cycle(bus) == cycle_before_refill + 314

    bus = Bus.idle(bus, 256)
    assert bus.apu.sample_a == 1
    assert APU.fifo_size(bus.apu, :a) == 31
    assert elem(bus.dma, 1).current_source == 0x0300_0020
  end

  test "transfers serial EEPROM commands and response bits through DMA3" do
    {:ok, cartridge} = TestROM.build("EEPROM_V124") |> Cartridge.load()
    bus = Bus.new(cartridge)
    data = <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0>>
    write_bits = [1, 0] ++ integer_bits(3, 6) ++ binary_bits(data) ++ [0]
    bus = write_halfword_bits(bus, 0x0300_0000, write_bits)
    bus = run_dma3(bus, 0x0300_0000, 0x0DFF_FF00, length(write_bits))

    read_bits = [1, 1] ++ integer_bits(3, 6) ++ [0]
    bus = write_halfword_bits(bus, 0x0300_0100, read_bits)
    bus = run_dma3(bus, 0x0300_0100, 0x0DFF_FF00, length(read_bits))
    bus = run_dma3(bus, 0x0DFF_FF00, 0x0300_0200, 68)

    response = for index <- 0..67, do: Bus.peek16(bus, 0x0300_0200 + index * 2) &&& 1
    assert Enum.take(response, 4) == [0, 0, 0, 0]
    assert response |> Enum.drop(4) |> bits_binary() == data
  end

  defp bus do
    {:ok, cartridge} = TestROM.build() |> Cartridge.load()
    Bus.new(cartridge)
  end

  defp run_dma3(bus, source, destination, count) do
    {bus, _cycles} = Bus.write32(bus, 0x0400_00D4, source)
    {bus, _cycles} = Bus.write32(bus, 0x0400_00D8, destination)
    {bus, _cycles} = Bus.write16(bus, 0x0400_00DC, count)
    {bus, _cycles} = Bus.write16(bus, 0x0400_00DE, 0x8000)
    bus
  end

  defp write_halfword_bits(bus, address, bits) do
    bits
    |> Enum.with_index()
    |> Enum.reduce(bus, fn {bit, index}, bus ->
      {bus, _cycles} = Bus.write16(bus, address + index * 2, bit)
      bus
    end)
  end

  defp integer_bits(value, count),
    do: for(bit <- Range.new(count - 1, 0, -1), do: value >>> bit &&& 1)

  defp binary_bits(binary), do: for(<<byte <- binary>>, bit <- 7..0//-1, do: byte >>> bit &&& 1)

  defp bits_binary(bits) do
    bits |> Enum.chunk_every(8) |> Enum.map(&bits_integer/1) |> :binary.list_to_bin()
  end

  defp bits_integer(bits), do: Enum.reduce(bits, 0, fn bit, value -> value <<< 1 ||| bit end)
end
