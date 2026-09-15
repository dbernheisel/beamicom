defmodule Beamicom.SNES.BusTest do
  use ExUnit.Case, async: true

  import Bitwise

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

  test "maps Cx4 RAM and mirrors its identity command across cartridge banks" do
    {:ok, cartridge} =
      :lorom |> SNESTestROM.build(cartridge_type: 0xF3) |> Cartridge.load()

    bus = Bus.new(cartridge)
    assert %Beamicom.SNES.Cx4{} = bus.coprocessor

    {bus, 8} = Bus.write(bus, 0x007F4F, 0x89)
    assert Bus.peek(bus, 0x807F80) == 0x36
    assert Bus.peek(bus, 0x807F81) == 0x43
    assert Bus.peek(bus, 0x807F82) == 0x05
    assert Bus.peek(bus, 0x007F5E) == 0
    assert bus.coprocessor.command_counts == %{0x89 => 1}
  end

  test "performs Cx4 ROM-to-RAM transfers from the cartridge bus" do
    media =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0xF3)
      |> SNESTestROM.put_bytes(0x0100, <<0x11, 0x22, 0x33>>)

    {:ok, cartridge} = Cartridge.load(media)

    bus = Bus.new(cartridge)
    {bus, 8} = Bus.write(bus, 0x007F40, 0x00)
    {bus, 8} = Bus.write(bus, 0x007F41, 0x81)
    {bus, 8} = Bus.write(bus, 0x007F42, 0x00)
    {bus, 8} = Bus.write(bus, 0x007F43, 3)
    {bus, 8} = Bus.write(bus, 0x007F44, 0)
    {bus, 8} = Bus.write(bus, 0x007F45, 0x00)
    {bus, 8} = Bus.write(bus, 0x007F46, 0x60)
    {bus, 8} = Bus.write(bus, 0x007F47, 0)

    assert [Bus.peek(bus, 0x006000), Bus.peek(bus, 0x006001), Bus.peek(bus, 0x006002)] ==
             [0x11, 0x22, 0x33]

    assert bus.coprocessor.load_count == 1
  end

  test "Cx4 trapezoid command generates clipped left and right scanline bounds" do
    {:ok, cartridge} =
      :lorom |> SNESTestROM.build(cartridge_type: 0xF3) |> Cartridge.load()

    bus = Bus.new(cartridge)

    registers = [
      {0x007F80, 10},
      {0x007F81, 0},
      {0x007F83, 10},
      {0x007F84, 0},
      {0x007F86, 100},
      {0x007F87, 0},
      {0x007F89, 12},
      {0x007F8A, 0},
      {0x007F8C, 0},
      {0x007F8D, 0},
      {0x007F8F, 0},
      {0x007F90, 0},
      {0x007F93, 20},
      {0x007F94, 0},
      {0x007F4D, 2}
    ]

    bus =
      Enum.reduce(registers, bus, fn {address, value}, bus ->
        {bus, 8} = Bus.write(bus, address, value)
        bus
      end)

    {bus, 8} = Bus.write(bus, 0x007F4F, 0x22)

    assert {Bus.peek(bus, 0x006800), Bus.peek(bus, 0x006900)} == {1, 0}
    assert {Bus.peek(bus, 0x006801), Bus.peek(bus, 0x006901)} == {1, 0}
    assert {Bus.peek(bus, 0x006802), Bus.peek(bus, 0x006902)} == {90, 110}
    assert {Bus.peek(bus, 0x0068E0), Bus.peek(bus, 0x0069E0)} == {90, 110}
    assert bus.coprocessor.unknown_commands == MapSet.new()
  end

  test "Cx4 build-OAM command expands composite sprites from ROM descriptors" do
    media =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0xF3)
      |> SNESTestROM.put_bytes(0x0100, <<1, 0x20, 5, 6, 3>>)

    {:ok, cartridge} = Cartridge.load(media)
    bus = Bus.new(cartridge)

    registers = [
      {0x006620, 1},
      {0x006621, 0},
      {0x006622, 0},
      {0x006623, 0},
      {0x006624, 0},
      {0x006626, 0},
      {0x006220, 10},
      {0x006221, 0},
      {0x006222, 20},
      {0x006223, 0},
      {0x006224, 1},
      {0x006225, 0x30},
      {0x006226, 2},
      {0x006227, 0x00},
      {0x006228, 0x81},
      {0x006229, 0x00},
      {0x007F4D, 0}
    ]

    bus =
      Enum.reduce(registers, bus, fn {address, value}, bus ->
        {bus, 8} = Bus.write(bus, address, value)
        bus
      end)

    {bus, 8} = Bus.write(bus, 0x007F4F, 0x00)

    assert for(address <- 0x006000..0x006003, do: Bus.peek(bus, address)) ==
             [15, 26, 0x33, 0x03]

    assert (Bus.peek(bus, 0x006200) &&& 3) == 2
    assert Bus.peek(bus, 0x006005) == 0xE0
    assert bus.coprocessor.unknown_commands == MapSet.new()
  end

  test "Cx4 scale/rotate converts packed pixels to SNES bitplanes" do
    {:ok, cartridge} =
      :lorom |> SNESTestROM.build(cartridge_type: 0xF3) |> Cartridge.load()

    bus = Bus.new(cartridge)

    bus =
      Enum.reduce(0x006600..0x00661F, bus, fn address, bus ->
        {bus, 8} = Bus.write(bus, address, 0xFF)
        bus
      end)

    registers = [
      {0x007F80, 0},
      {0x007F81, 0},
      {0x007F83, 4},
      {0x007F84, 0},
      {0x007F86, 4},
      {0x007F87, 0},
      {0x007F89, 8},
      {0x007F8C, 8},
      {0x007F8F, 0},
      {0x007F90, 0x10},
      {0x007F92, 0},
      {0x007F93, 0x10},
      {0x007F4D, 3}
    ]

    bus =
      Enum.reduce(registers, bus, fn {address, value}, bus ->
        {bus, 8} = Bus.write(bus, address, value)
        bus
      end)

    {bus, 8} = Bus.write(bus, 0x007F4F, 0)

    assert for(
             row <- 0..7,
             plane <- [0, 1, 16, 17],
             do: Bus.peek(bus, 0x006000 + row * 2 + plane)
           ) ==
             List.duplicate(0xFF, 32)

    assert bus.coprocessor.unknown_commands == MapSet.new()
  end

  test "Cx4 vector, polar, and coordinate transforms produce fixed-width results" do
    {:ok, cartridge} =
      :lorom |> SNESTestROM.build(cartridge_type: 0xF3) |> Cartridge.load()

    bus =
      Bus.new(cartridge)
      |> write_registers([
        {0x007F80, 3},
        {0x007F83, 4},
        {0x007F86, 10},
        {0x007F4D, 2}
      ])

    {bus, 8} = Bus.write(bus, 0x007F4F, 0x0D)
    assert {Bus.peek(bus, 0x007F89), Bus.peek(bus, 0x007F8C)} == {5, 7}

    bus = write_registers(bus, [{0x007F80, 0}, {0x007F81, 0}, {0x007F83, 0}, {0x007F84, 1}])
    {bus, 8} = Bus.write(bus, 0x007F4F, 0x10)
    assert read_cx4(bus, 0x7F86, 3) == 255
    assert read_cx4(bus, 0x7F89, 3) == 0

    bus = write_registers(bus, [{0x007F80, 128}, {0x007F81, 0}, {0x007F83, 1}, {0x007F84, 0}])
    {bus, 8} = Bus.write(bus, 0x007F4F, 0x13)
    assert read_cx4(bus, 0x7F86, 3) == 0
    assert read_cx4(bus, 0x7F89, 3) == 255

    bus =
      write_registers(bus, [
        {0x007F81, 10},
        {0x007F82, 0},
        {0x007F84, 0xEC},
        {0x007F85, 0xFF},
        {0x007F87, 30},
        {0x007F88, 0},
        {0x007F89, 0},
        {0x007F8A, 0},
        {0x007F8B, 0},
        {0x007F90, 0},
        {0x007F91, 1}
      ])

    {bus, 8} = Bus.write(bus, 0x007F4F, 0x2D)
    assert read_cx4(bus, 0x7F80, 2) == 10
    assert read_cx4(bus, 0x7F83, 2) == 0xFFEC
    assert bus.coprocessor.unknown_commands == MapSet.new()
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

  test "reads standard joypads serially in hardware button order", %{bus: bus} do
    report = 0xA510
    bus = Bus.set_joypad(bus, 1, report)
    {bus, 12} = Bus.write(bus, 0x004016, 1)
    {bus, 12} = Bus.write(bus, 0x004016, 0)

    {bits, bus} =
      Enum.map_reduce(1..16, bus, fn _, bus ->
        {value, bus, 12} = Bus.read(bus, 0x004016)
        {value &&& 1, bus}
      end)

    assert bits == for(bit <- 15..0//-1, do: report >>> bit &&& 1)
    assert {value, _bus, 12} = Bus.read(bus, 0x004016)
    assert (value &&& 1) == 1
  end

  test "automatic vblank reads populate JOY registers and report busy", %{bus: bus} do
    bus = Bus.set_joypad(bus, 1, 0xA510)
    {bus, 6} = Bus.write(bus, 0x004200, 0x01)
    bus = Bus.advance_master(bus, 225 * 1364 - 6)

    assert {status, bus, 6} = Bus.read(bus, 0x004212)
    assert (status &&& 1) == 0

    bus = Bus.advance_master(bus, 122)
    assert {0x10, bus, 6} = Bus.read(bus, 0x004218)
    assert {0xA5, bus, 6} = Bus.read(bus, 0x004219)
    assert {status, bus, 6} = Bus.read(bus, 0x004212)
    assert (status &&& 1) == 1

    bus = Bus.advance_master(bus, 4224)
    assert {status, _bus, 6} = Bus.read(bus, 0x004212)
    assert (status &&& 1) == 0
  end

  defp write_registers(bus, registers) do
    Enum.reduce(registers, bus, fn {address, value}, bus ->
      {bus, _clocks} = Bus.write(bus, address, value)
      bus
    end)
  end

  defp read_cx4(bus, address, bytes) do
    Enum.reduce(0..(bytes - 1), 0, fn index, value ->
      value ||| Bus.peek(bus, address + index) <<< (index * 8)
    end)
  end
end
