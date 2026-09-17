defmodule Beamicom.SNES.PPUMemoryAccessTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{Bus, Cartridge}
  alias Beamicom.SNESTestROM

  setup do
    {:ok, cartridge} = :lorom |> SNESTestROM.build() |> Cartridge.load()
    %{bus: Bus.new(cartridge)}
  end

  test "VRAM access is blocked for the whole visible scanline", %{bus: bus} do
    bus = write_vram_word(bus, 0, 0xBBAA)
    bus = bus |> write(0x2100, 0x0F) |> position(1, 100)
    bus = write_vram_word(bus, 0, 0x2211)

    assert vram_word(bus, 0) == 0xBBAA
    assert bus.ppu.vmadd == 1

    bus = bus |> position(1, 1112) |> write_vram_word(0, 0x4433)
    assert vram_word(bus, 0) == 0xBBAA

    bus = bus |> position(225, 100) |> write_vram_word(0, 0x6655)
    assert vram_word(bus, 0) == 0x6655

    bus = bus |> position(1, 100) |> write(0x2100, 0x8F) |> write_vram_word(0, 0x8877)
    assert vram_word(bus, 0) == 0x8877
  end

  test "active-display VRAM reads load zero while preserving increment semantics", %{bus: bus} do
    bus = write_vram_word(bus, 0, 0xBBAA)
    bus = bus |> write(0x2100, 0x0F) |> position(1, 100) |> set_vmadd(0)

    assert {0, bus, 6} = Bus.read(bus, 0x002139)
    assert {0, bus, 6} = Bus.read(bus, 0x00213A)
    assert bus.ppu.vmadd == 1

    bus = bus |> position(225, 100) |> set_vmadd(0)
    assert {0xAA, bus, 6} = Bus.read(bus, 0x002139)
    assert {0xBB, _bus, 6} = Bus.read(bus, 0x00213A)
  end

  test "OAM does not access the programmer address during visible scanlines", %{bus: bus} do
    bus = write_oam_word(bus, 2, 0x12, 0x34)
    bus = bus |> write(0x2100, 0x0F) |> position(1, 100)
    before_version = bus.ppu.oam_version

    bus = write_oam_word(bus, 2, 0xAA, 0xBB)

    assert oam_word(bus, 2) == {0x12, 0x34}
    assert bus.ppu.oam_internal_address == 6
    assert bus.ppu.oam_version == before_version

    bus = bus |> position(1, 1112) |> write_oam_word(2, 0xCC, 0xDD)
    assert oam_word(bus, 2) == {0x12, 0x34}

    bus = bus |> position(225, 100) |> write_oam_word(2, 0x56, 0x78)
    assert oam_word(bus, 2) == {0x56, 0x78}

    bus = bus |> position(1, 100) |> write(0x2100, 0x8F) |> write_oam_word(2, 0x9A, 0xBC)
    assert oam_word(bus, 2) == {0x9A, 0xBC}
  end

  test "active-display OAM reads preserve CPU-side address progression", %{bus: bus} do
    bus = write_oam_word(bus, 2, 0x12, 0x34)

    bus =
      bus
      |> write(0x2100, 0x0F)
      |> position(1, 100)
      |> set_oam_address(2)
      |> Bus.put_open_bus(0xA5)

    assert {0xA5, bus, 6} = Bus.read(bus, 0x002138)
    assert bus.ppu.oam_internal_address == 5

    bus = bus |> position(225, 100) |> set_oam_address(2)
    assert {0x12, _bus, 6} = Bus.read(bus, 0x002138)
  end

  test "CGRAM redirects only during its active fetch window", %{bus: bus} do
    bus = write_cgram_color(bus, 3, 0x1234)
    bus = bus |> write(0x2100, 0x0F) |> position(1, 100)
    bus = write_cgram_color(bus, 3, 0x5678)

    assert :array.get(3, bus.ppu.cgram) == 0x1234
    assert bus.ppu.cgadd == 4
    refute bus.ppu.cgram_second_byte?

    bus = bus |> position(1, 1112) |> write_cgram_color(3, 0x2345)
    assert :array.get(3, bus.ppu.cgram) == 0x2345

    bus = bus |> position(225, 100) |> write_cgram_color(3, 0x3456)
    assert :array.get(3, bus.ppu.cgram) == 0x3456

    bus = bus |> position(1, 100) |> write(0x2100, 0x8F) |> write_cgram_color(3, 0x4567)
    assert :array.get(3, bus.ppu.cgram) == 0x4567
  end

  test "active-display CGRAM reads preserve phase and address progression", %{bus: bus} do
    bus = write_cgram_color(bus, 3, 0x1234)

    bus =
      bus
      |> write(0x2100, 0x0F)
      |> position(1, 100)
      |> write(0x2121, 3)
      |> Bus.put_open_bus(0xA5)

    assert {0xA5, bus, 6} = Bus.read(bus, 0x00213B)
    assert bus.ppu.cgram_second_byte?
    assert {0xA5, bus, 6} = Bus.read(bus, 0x00213B)
    assert bus.ppu.cgadd == 4
    refute bus.ppu.cgram_second_byte?

    bus = bus |> position(1, 1112) |> write(0x2121, 3)
    assert {0x34, bus, 6} = Bus.read(bus, 0x00213B)
    assert {0x12, _bus, 6} = Bus.read(bus, 0x00213B)
  end

  test "DMA PPU accesses use the current beam position", %{bus: bus} do
    bus = write_vram_word(bus, 0, 0xBBAA)
    {bus, 8} = Bus.write(bus, 0x7E0000, 0x11)
    {bus, 8} = Bus.write(bus, 0x7E0001, 0x22)

    bus =
      bus
      |> configure_vram_dma()
      |> write(0x2100, 0x0F)
      |> position(1, 100)
      |> set_vmadd(0)
      |> write(0x420B, 1)

    assert vram_word(bus, 0) == 0xBBAA

    bus =
      bus
      |> configure_vram_dma()
      |> position(225, 100)
      |> set_vmadd(0)
      |> write(0x420B, 1)

    assert vram_word(bus, 0) == 0x2211
  end

  defp write(bus, register, value) do
    {bus, 6} = Bus.write(bus, 0x000000 ||| register, value)
    bus
  end

  defp position(bus, vline, hclock) do
    bus
    |> Map.put(:timing, %{bus.timing | vline: vline, hclock: hclock})
    |> Bus.put_cpu_pending_clocks(0)
  end

  defp set_vmadd(bus, address) do
    bus
    |> write(0x2115, 0x80)
    |> write(0x2116, address &&& 0xFF)
    |> write(0x2117, address >>> 8)
  end

  defp write_vram_word(bus, address, value) do
    bus
    |> set_vmadd(address)
    |> write(0x2118, value &&& 0xFF)
    |> write(0x2119, value >>> 8)
  end

  defp vram_word(bus, address) do
    low = :array.get(address * 2, bus.ppu.vram)
    high = :array.get(address * 2 + 1, bus.ppu.vram)
    low ||| high <<< 8
  end

  defp set_oam_address(bus, word_address) do
    bus
    |> write(0x2102, word_address &&& 0xFF)
    |> write(0x2103, word_address >>> 8 &&& 1)
  end

  defp write_oam_word(bus, word_address, low, high) do
    bus
    |> set_oam_address(word_address)
    |> write(0x2104, low)
    |> write(0x2104, high)
  end

  defp oam_word(bus, word_address) do
    address = word_address * 2
    {:array.get(address, bus.ppu.oam), :array.get(address + 1, bus.ppu.oam)}
  end

  defp write_cgram_color(bus, address, color) do
    bus
    |> write(0x2121, address)
    |> write(0x2122, color &&& 0xFF)
    |> write(0x2122, color >>> 8)
  end

  defp configure_vram_dma(bus) do
    bus
    |> write(0x4300, 0x01)
    |> write(0x4301, 0x18)
    |> write(0x4302, 0)
    |> write(0x4303, 0)
    |> write(0x4304, 0x7E)
    |> write(0x4305, 2)
    |> write(0x4306, 0)
  end
end
