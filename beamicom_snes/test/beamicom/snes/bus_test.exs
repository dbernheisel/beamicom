defmodule Beamicom.SNES.BusTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{Bus, Cartridge}
  alias Beamicom.SNESTestROM

  setup do
    {:ok, cartridge} = :lorom |> SNESTestROM.build() |> Cartridge.load()
    %{bus: Bus.new(cartridge)}
  end

  test "mirrors low WRAM and maps both full WRAM banks", %{bus: bus} do
    {bus, 8} = Bus.write(bus, 0x000123, 0x42)
    assert Bus.peek(bus, 0x800123) == 0x42
    assert Bus.peek(bus, 0x7E0123) == 0x42

    {bus, 8} = Bus.write(bus, 0x7F0020, 0x99)
    assert Bus.peek(bus, 0x7F0020) == 0x99
  end

  test "persists cartridge SRAM through LoROM mirrors" do
    {:ok, cartridge} = :lorom |> SNESTestROM.build(ram_size_code: 3) |> Cartridge.load()
    bus = Bus.new(cartridge)

    assert Bus.peek(bus, 0x700123) == 0xFF
    {bus, 8} = Bus.write(bus, 0x700123, 0x42)
    assert Bus.peek(bus, 0x702123) == 0x42
    assert Bus.peek(bus, 0xF00123) == 0x42
  end

  test "prices WRAM, MMIO, JOYSER, slow ROM, and fast ROM accesses", %{bus: bus} do
    assert Bus.access_clocks(bus, 0x7E0000) == 8
    assert Bus.access_clocks(bus, 0x002100) == 6
    assert Bus.access_clocks(bus, 0x004016) == 12
    assert Bus.access_clocks(bus, 0x008000) == 8
    assert Bus.access_clocks(bus, 0x808000) == 8

    {bus, 6} = Bus.write(bus, 0x00420D, 1)
    assert bus.fast_rom?
    assert Bus.access_clocks(bus, 0x008000) == 8
    assert Bus.access_clocks(bus, 0x808000) == 6
  end

  test "advances the master clock for every bus and internal cycle", %{bus: bus} do
    {_value, bus, 8} = Bus.read(bus, 0x008000)
    {bus, 6} = Bus.write(bus, 0x002100, 0x80)
    {bus, 12} = Bus.idle(bus, 2)
    assert bus.timing.master_clocks == 26
    assert bus.timing.hclock == 26
  end

  test "WRAM data port auto-increments its 17-bit address", %{bus: bus} do
    {bus, 6} = Bus.write(bus, 0x002181, 0xFE)
    {bus, 6} = Bus.write(bus, 0x002182, 0xFF)
    {bus, 6} = Bus.write(bus, 0x002183, 0x01)
    {bus, 6} = Bus.write(bus, 0x002180, 0x42)
    {bus, 6} = Bus.write(bus, 0x002180, 0x99)

    assert bus.wmadd == 0
    assert Bus.peek(bus, 0x7FFFFE) == 0x42
    assert Bus.peek(bus, 0x7FFFFF) == 0x99

    {value, bus, 6} = Bus.read(bus, 0x002180)
    assert value == 0
    assert bus.wmadd == 1
  end

  test "general DMA transfers CPU memory through B-bus register patterns", %{bus: bus} do
    {bus, 8} = Bus.write(bus, 0x7E0000, 0xAA)
    {bus, 8} = Bus.write(bus, 0x7E0001, 0xBB)
    {bus, 6} = Bus.write(bus, 0x002115, 0x80)
    {bus, 6} = Bus.write(bus, 0x002116, 0)
    {bus, 6} = Bus.write(bus, 0x002117, 0)
    {bus, 6} = Bus.write(bus, 0x004300, 0x01)
    {bus, 6} = Bus.write(bus, 0x004301, 0x18)
    {bus, 6} = Bus.write(bus, 0x004302, 0)
    {bus, 6} = Bus.write(bus, 0x004303, 0)
    {bus, 6} = Bus.write(bus, 0x004304, 0x7E)
    {bus, 6} = Bus.write(bus, 0x004305, 2)
    {bus, 6} = Bus.write(bus, 0x004306, 0)

    before = bus.timing.master_clocks
    {bus, 6} = Bus.write(bus, 0x00420B, 1)
    assert bus.timing.master_clocks - before == 30
    assert elem(bus.dma_channels, 0).size == 0
    assert elem(bus.dma_channels, 0).a_addr == 2

    ppu = bus.ppu |> Beamicom.SNES.PPU.write(0x2116, 0) |> Beamicom.SNES.PPU.write(0x2117, 0)
    assert {0xAA, ppu} = Beamicom.SNES.PPU.read(ppu, 0x2139, 0)
    assert {0xBB, _ppu} = Beamicom.SNES.PPU.read(ppu, 0x213A, 0)
  end

  test "exposes the CPU multiplication and division result registers", %{bus: bus} do
    {bus, 6} = Bus.write(bus, 0x004202, 13)
    {bus, 6} = Bus.write(bus, 0x004203, 17)
    assert {221, bus, 6} = Bus.read(bus, 0x004216)
    assert {0, bus, 6} = Bus.read(bus, 0x004217)

    {bus, 6} = Bus.write(bus, 0x004204, 0x34)
    {bus, 6} = Bus.write(bus, 0x004205, 0x12)
    {bus, 6} = Bus.write(bus, 0x004206, 10)
    assert {0xD2, bus, 6} = Bus.read(bus, 0x004214)
    assert {0x01, bus, 6} = Bus.read(bus, 0x004215)
    assert {0x00, bus, 6} = Bus.read(bus, 0x004216)
    assert {0x00, _bus, 6} = Bus.read(bus, 0x004217)
  end
end
