defmodule Beamicom.GB.DiagnosticROMTest do
  use ExUnit.Case, async: true

  alias Beamicom.GB.{Bus, DiagnosticROM, Machine, PPU}

  test "CPU-executed ROM configures video memory and renders a recognizable scene" do
    rom = DiagnosticROM.build()
    assert byte_size(rom) == 32 * 1024
    assert {:ok, machine} = Machine.load(rom)

    # The machine starts with blank VRAM; only execution of the ROM can alter it.
    assert PPU.read(machine.bus.ppu, 0x8000) == 0
    assert {:ok, machine, 0, frame} = Machine.run_until_frame(machine)

    assert byte_size(frame) == 160 * 144
    assert MapSet.new(:binary.bin_to_list(frame)) == MapSet.new(0..3)
    assert :erlang.crc32(frame) == 2_030_719_324
    assert PPU.read(machine.bus.ppu, 0x8000) == 0
    assert PPU.read(machine.bus.ppu, 0x8010) == 0xFF
    assert PPU.read(machine.bus.ppu, 0x8040) != 0
    assert PPU.read(machine.bus.ppu, 0xFF40) == 0xF3
    assert PPU.read(machine.bus.ppu, 0xFF47) == 0xE4
    assert machine.cpu.pc == 0x01A8

    # Background G, window B, border, and sprite diamonds occupy distinct regions.
    assert pixel(frame, 4, 4) == 2
    assert pixel(frame, 24, 32) == 3
    assert pixel(frame, 100, 36) == 3
    assert pixel(frame, 19, 130) == 3
  end

  defp pixel(frame, x, y), do: :binary.at(frame, y * 160 + x)

  test "CPU-executed CGB ROM initializes both VRAM banks, palettes, attributes, and OAM DMA" do
    rom = DiagnosticROM.build_cgb()
    assert byte_size(rom) == 32 * 1024
    assert {:ok, machine} = Machine.load(rom)
    assert machine.model == :cgb

    # CGB video state starts blank/white. The ROM receives only cartridge
    # bytes, so every later visual mutation must come from executed SM83 code.
    assert machine.bus.ppu.vram == PPU.new(model: :cgb).vram
    assert machine.bus.ppu.color_ram == PPU.new(model: :cgb).color_ram
    assert machine.bus.ppu.frame == :binary.copy(<<255>>, 160 * 144 * 3)

    assert {:ok, machine, 0, frame} = Machine.run_until_frame(machine)
    assert byte_size(frame) == 160 * 144 * 3
    assert length(Enum.uniq(for <<rgb::binary-size(3) <- frame>>, do: rgb)) == 26
    assert :erlang.crc32(frame) == 642_352_328
    assert machine.cpu.pc == 0x01DC

    lcd_off = Bus.write(machine.bus, 0xFF40, 0)
    bank0 = Bus.write(lcd_off, 0xFF4F, 0)
    bank1 = Bus.write(lcd_off, 0xFF4F, 1)
    assert Bus.read(bank0, 0x8010) == 0xFF
    assert Bus.read(bank1, 0x8010) == 0xAA
    assert Bus.read(bank0, 0x9800) == 2
    assert Bus.read(bank1, 0x9800) == 0x88
    assert binary_part(machine.bus.ppu.oam, 0, 4) == <<64, 24, 4, 4>>
    refute machine.bus.ppu.color_ram == PPU.new(model: :cgb).color_ram

    assert cgb_pixel(frame, 0, 0) == <<255, 82, 90>>
    assert cgb_pixel(frame, 4, 4) == <<132, 0, 0>>
    assert cgb_pixel(frame, 40, 48) == <<0, 255, 123>>
    assert cgb_pixel(frame, 80, 10) == <<0, 74, 255>>
  end

  defp cgb_pixel(frame, x, y), do: binary_part(frame, (y * 160 + x) * 3, 3)
end
