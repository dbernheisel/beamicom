defmodule Beamicom.SNES.BusTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{APU, Bus, Cartridge, DSPTask, PPU}
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

  test "audio drain publishes an in-flight DSP batch without new clocks", %{bus: bus} do
    apu = APU.new(native_ipl: true, async_dsp: true) |> APU.advance(357_368, :ntsc)
    assert %DSPTask{} = apu.dsp_task

    {frames, pcm, bus} = Bus.take_audio_pcm(%{bus | apu: apu, apu_pending_clocks: 0})

    assert frames > 0
    assert byte_size(pcm) == frames * 4
    assert bus.apu.dsp_task == nil
  end

  test "CPU raster writes preserve the preceding scanline state", %{bus: bus} do
    bus = Bus.advance_master(bus, 10 * 1364)
    {bus, 6} = Bus.write(bus, 0x00212C, 0x00)
    assert bus.ppu.scanline_states == nil

    {bus, 6} = Bus.write(bus, 0x00212C, 0x01)

    assert length(bus.ppu.scanline_states) == 10
    assert Enum.all?(bus.ppu.scanline_states, &(elem(&1, 13) == 0))

    bus = Bus.advance_master(bus, 1364 - 12)

    assert length(bus.ppu.scanline_states) == 11
    assert elem(hd(bus.ppu.scanline_states), 13) == 0x01
  end

  test "HBlank writes do not create zero-width raster segments", %{bus: bus} do
    line = 10
    hblank_start = 88 + 256 * 4
    bus = Bus.advance_master(bus, line * 1364 + hblank_start)

    {bus, 6} = Bus.write(bus, 0x00212C, 0x01)

    assert bus.ppu.raster_segments == %{}
    assert length(bus.ppu.scanline_states) == line
  end

  test "HDMA starts after line 0 and holds each table entry for its full line count", %{bus: bus} do
    dma = %{elem(bus.dma_channels, 0) | bbad: 0x2C, a_bank: 0x7E}

    wram =
      [{0, 3}, {1, 0x01}, {2, 1}, {3, 0x02}, {4, 0}]
      |> Enum.reduce(bus.wram, fn {address, value}, wram ->
        :array.set(address, value, wram)
      end)

    timing = %{bus.timing | vline: 261, hclock: 1360}

    bus = %{
      bus
      | dma_channels: put_elem(bus.dma_channels, 0, dma),
        hdma_enable: 1,
        timing: timing,
        wram: wram
    }

    bus = Bus.advance_master(bus, 4)
    assert bus.timing.vline == 0
    assert bus.ppu.scanline_states == []
    assert elem(bus.dma_channels, 0).line_counter == 0

    bus = Bus.advance_master(bus, 1364)
    assert elem(hd(bus.ppu.scanline_states), 13) == 0x01

    bus = Bus.advance_master(bus, 2 * 1364)
    assert bus.timing.vline == 3
    assert Enum.map(bus.ppu.scanline_states, &elem(&1, 13)) == [0x01, 0x01, 0x01]

    bus = Bus.advance_master(bus, 1364)
    assert bus.timing.vline == 4
    assert Enum.map(bus.ppu.scanline_states, &elem(&1, 13)) == [0x02, 0x01, 0x01, 0x01]
  end

  test "left-edge raster writes affect the current visible row", %{bus: bus} do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2121, 0)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0)

    line = 10
    screen_line = line - 1
    bus = Bus.advance_master(%{bus | ppu: ppu}, line * 1364)
    {bus, 6} = Bus.write(bus, 0x002100, 0x80)

    assert [{0, state}] = Map.fetch!(bus.ppu.raster_segments, screen_line)
    assert elem(state, 0)

    bus = Bus.advance_master(bus, 225 * 1364 - bus.timing.master_clocks)
    {frame, _bus} = Bus.take_frame(bus)

    assert pixel_at(frame.data, 255, screen_line - 1) == <<255, 0, 0>>
    assert pixel_at(frame.data, 0, screen_line) == <<0, 0, 0>>
  end

  test "mid-scanline INIDISP writes affect only subsequent pixels", %{bus: bus} do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2121, 0)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0)

    line = 10
    screen_line = line - 1
    x = 96
    target_clock = line * 1364 + 88 + x * 4
    bus = Bus.advance_master(%{bus | ppu: ppu}, target_clock)
    {bus, 6} = Bus.write(bus, 0x002100, 0x80)

    assert [{0, before}, {^x, after_write}] =
             Map.fetch!(bus.ppu.raster_segments, screen_line)

    refute elem(before, 0)
    assert elem(after_write, 0)

    bus = Bus.advance_master(bus, 225 * 1364 - bus.timing.master_clocks)
    {frame, _bus} = Bus.take_frame(bus)

    assert pixel_at(frame.data, x - 1, screen_line) == <<255, 0, 0>>
    assert pixel_at(frame.data, x, screen_line) == <<0, 0, 0>>
    assert pixel_at(frame.data, 255, screen_line - 1) == <<255, 0, 0>>
    assert pixel_at(frame.data, 0, screen_line + 1) == <<0, 0, 0>>
  end

  test "multiple mid-scanline color-math writes form ordered spans", %{bus: bus} do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2121, 0)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0)
      |> PPU.write(0x2132, 0x9F)
      |> PPU.write(0x2131, 0x20)

    line = 12
    screen_line = line - 1
    first_x = 64
    second_x = 160
    first_clock = line * 1364 + 88 + first_x * 4
    second_clock = line * 1364 + 88 + second_x * 4

    bus = Bus.advance_master(%{bus | ppu: ppu}, first_clock)
    {bus, 6} = Bus.write(bus, 0x002131, 0)
    bus = Bus.advance_master(bus, second_clock - bus.timing.master_clocks)
    {bus, 6} = Bus.write(bus, 0x002131, 0x20)

    assert [{0, _before}, {^first_x, _middle}, {^second_x, _after}] =
             Map.fetch!(bus.ppu.raster_segments, screen_line)

    bus = Bus.advance_master(bus, 225 * 1364 - bus.timing.master_clocks)
    {frame, _bus} = Bus.take_frame(bus)

    assert pixel_at(frame.data, first_x - 1, screen_line) == <<255, 0, 255>>
    assert pixel_at(frame.data, first_x, screen_line) == <<255, 0, 0>>
    assert pixel_at(frame.data, second_x - 1, screen_line) == <<255, 0, 0>>
    assert pixel_at(frame.data, second_x, screen_line) == <<255, 0, 255>>
  end

  test "mid-scanline window writes preserve pixels already drawn", %{bus: bus} do
    ppu =
      PPU.new()
      |> PPU.write(0x2100, 0x0F)
      |> PPU.write(0x2121, 0)
      |> PPU.write(0x2122, 0x1F)
      |> PPU.write(0x2122, 0)
      |> PPU.write(0x2125, 0x20)
      |> PPU.write(0x2126, 0)
      |> PPU.write(0x2127, 63)
      |> PPU.write(0x2130, 0x80)
      |> PPU.write(0x2131, 0x20)

    line = 14
    screen_line = line - 1
    x = 128
    target_clock = line * 1364 + 88 + x * 4
    bus = Bus.advance_master(%{bus | ppu: ppu}, target_clock)
    {bus, 6} = Bus.write(bus, 0x002127, 191)
    bus = Bus.advance_master(bus, 225 * 1364 - bus.timing.master_clocks)
    {frame, _bus} = Bus.take_frame(bus)

    assert pixel_at(frame.data, 63, screen_line) == <<0, 0, 0>>
    assert pixel_at(frame.data, 64, screen_line) == <<255, 0, 0>>
    assert pixel_at(frame.data, x - 1, screen_line) == <<255, 0, 0>>
    assert pixel_at(frame.data, x, screen_line) == <<0, 0, 0>>
    assert pixel_at(frame.data, 191, screen_line) == <<0, 0, 0>>
    assert pixel_at(frame.data, 192, screen_line) == <<255, 0, 0>>
  end

  test "persists cartridge SRAM through LoROM mirrors" do
    {:ok, cartridge} = :lorom |> SNESTestROM.build(ram_size_code: 3) |> Cartridge.load()
    bus = Bus.new(cartridge)

    assert Bus.peek(bus, 0x700123) == 0xFF
    {bus, 8} = Bus.write(bus, 0x700123, 0x42)
    assert Bus.peek(bus, 0x702123) == 0x42
    assert Bus.peek(bus, 0xF00123) == 0x42
  end

  test "reads HiROM directly and persists its SRAM mirrors" do
    media =
      :hirom
      |> SNESTestROM.build(ram_size_code: 3)
      |> SNESTestROM.put_byte(0x1234, 0x5A)

    {:ok, cartridge} = Cartridge.load(media)
    bus = Bus.new(cartridge)

    assert {0x5A, bus, 8} = Bus.cpu_read(bus, 0xC01234)
    assert Bus.peek(bus, 0x401234) == 0x5A

    bus = Bus.put_open_bus(bus, 0xA5)
    assert {0xA5, bus, 8} = Bus.cpu_read(bus, 0x106000)

    {bus, 8} = Bus.cpu_write(bus, 0x206001, 0x42)
    assert {0x42, _bus, 8} = Bus.cpu_read(bus, 0xA06001)
    assert Bus.peek(bus, 0x216001) == 0x42
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

  test "$2137 latches the current beam position when WRIO bit 7 is high", %{bus: bus} do
    bus = %{bus | timing: %{bus.timing | hclock: 1_200, vline: 258}}
    {open_bus, bus, 6} = Bus.read(Bus.put_open_bus(bus, 0xA5), 0x002137)

    assert open_bus == 0xA5
    assert bus.ppu.latched_hcounter == 300
    assert bus.ppu.latched_vcounter == 258

    assert {0x2C, bus, 6} = Bus.read(bus, 0x00213C)
    assert {0x2D, bus, 6} = Bus.read(bus, 0x00213C)
    assert {0x02, bus, 6} = Bus.read(bus, 0x00213D)
    assert {0x03, _bus, 6} = Bus.read(bus, 0x00213D)
  end

  test "$4201 falling edge latches counters and gates software latching", %{bus: bus} do
    bus = %{bus | timing: %{bus.timing | hclock: 400, vline: 12}}
    {bus, 6} = Bus.write(bus, 0x004201, 0x00)

    assert bus.ppu.latched_hcounter == 100
    assert bus.ppu.latched_vcounter == 12
    assert {0x00, bus, 6} = Bus.read(bus, 0x004213)

    bus = %{bus | timing: %{bus.timing | hclock: 800, vline: 24}}
    {_open_bus, bus, 6} = Bus.read(bus, 0x002137)
    assert bus.ppu.latched_hcounter == 100
    assert bus.ppu.latched_vcounter == 12

    {bus, 6} = Bus.write(bus, 0x004201, 0x80)
    {_open_bus, bus, 6} = Bus.read(bus, 0x002137)
    assert bus.ppu.latched_hcounter == 203
    assert bus.ppu.latched_vcounter == 24
  end

  test "$213F resets both counter read phases", %{bus: bus} do
    bus = %{bus | timing: %{bus.timing | hclock: 1_200, vline: 258}}
    {_open_bus, bus, 6} = Bus.read(bus, 0x002137)
    assert {0x2C, bus, 6} = Bus.read(bus, 0x00213C)
    assert {0x02, bus, 6} = Bus.read(bus, 0x00213D)
    {_status, bus, 6} = Bus.read(bus, 0x00213F)
    assert {0x2C, bus, 6} = Bus.read(bus, 0x00213C)
    assert {0x02, _bus, 6} = Bus.read(bus, 0x00213D)
  end

  test "$213F reports region and field while preserving PPU2 MDR bit 5" do
    {:ok, cartridge} = :lorom |> SNESTestROM.build() |> Cartridge.load()
    bus = Bus.new(cartridge, region: :pal)
    bus = %{bus | timing: %{bus.timing | field: 1}, ppu: %{bus.ppu | ppu2_mdr: 0x20}}

    assert {0xB3, bus, 6} = Bus.read(bus, 0x00213F)
    assert bus.ppu.ppu2_mdr == 0xB3
  end

  test "PPU write-only reads use the corresponding PPU MDR rather than CPU open bus", %{bus: bus} do
    ppu = %{bus.ppu | m7_product: 0x5A, latched_hcounter: 0x0AB}
    bus = %{bus | ppu: ppu}

    assert {0x5A, bus, 6} = Bus.read(bus, 0x002134)
    assert {0xAB, bus, 6} = Bus.read(bus, 0x00213C)
    assert Bus.open_bus(bus) == 0xAB

    assert {0x5A, bus, 6} = Bus.read(bus, 0x002104)
    assert bus.ppu.ppu1_mdr == 0x5A
    assert bus.ppu.ppu2_mdr == 0xAB
  end

  test "$213F reports and clears a counter latch only while WRIO enables it", %{bus: bus} do
    bus = %{bus | timing: %{bus.timing | hclock: 400, vline: 12}}
    {bus, 6} = Bus.write(bus, 0x004201, 0x00)

    assert bus.ppu.counter_latched?
    assert {status, bus, 6} = Bus.read(bus, 0x00213F)
    assert (status &&& 0x40) != 0
    assert bus.ppu.counter_latched?

    {bus, 6} = Bus.write(bus, 0x004201, 0x80)
    assert {status, bus, 6} = Bus.read(bus, 0x00213F)
    assert (status &&& 0x40) != 0
    refute bus.ppu.counter_latched?

    assert {status, _bus, 6} = Bus.read(bus, 0x00213F)
    refute (status &&& 0x40) != 0
  end

  test "CPU PPU reads latch after pending CPU clocks are synchronized", %{bus: bus} do
    {bus, 60} = Bus.cpu_idle(bus, 10)
    {_open_bus, bus, 6} = Bus.cpu_read(bus, 0x002137)

    assert bus.timing.hclock == 60
    assert Bus.cpu_pending_clocks(bus) == 6
    assert bus.ppu.latched_hcounter == 15
    assert bus.ppu.latched_vcounter == 0
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

  test "reverse DMA preserves PPU read side effects between bytes", %{bus: bus} do
    bus =
      Enum.reduce([0x12, 0x34, 0x56, 0x78], bus, fn value, bus ->
        {bus, 6} = Bus.write(bus, 0x002104, value)
        bus
      end)

    {bus, 6} = Bus.write(bus, 0x002102, 0)
    {bus, 6} = Bus.write(bus, 0x002103, 0)
    {bus, 6} = Bus.write(bus, 0x004300, 0x80)
    {bus, 6} = Bus.write(bus, 0x004301, 0x38)
    {bus, 6} = Bus.write(bus, 0x004302, 0)
    {bus, 6} = Bus.write(bus, 0x004303, 0)
    {bus, 6} = Bus.write(bus, 0x004304, 0x7E)
    {bus, 6} = Bus.write(bus, 0x004305, 2)
    {bus, 6} = Bus.write(bus, 0x004306, 0)
    {bus, 6} = Bus.write(bus, 0x00420B, 1)

    assert Bus.peek(bus, 0x7E0000) == 0x12
    assert Bus.peek(bus, 0x7E0001) == 0x34
    assert bus.ppu.oam_internal_address == 2
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

  defp pixel_at(frame_data, x, y), do: binary_part(frame_data, (y * 256 + x) * 3, 3)

  defp read_cx4(bus, address, bytes) do
    Enum.reduce(0..(bytes - 1), 0, fn index, value ->
      value ||| Bus.peek(bus, address + index) <<< (index * 8)
    end)
  end
end
