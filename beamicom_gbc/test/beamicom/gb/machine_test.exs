defmodule Beamicom.GB.MachineTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.{Bus, Machine, PPU}

  @frame_dots 456 * 154

  test "post-boot CPU writes flow into the single authoritative PPU and produce a frame" do
    assert {:ok, machine} = Machine.load(rom())
    assert {machine.cpu.pc, machine.cpu.sp, machine.cpu.a} == {0x0100, 0xFFFE, 0x01}
    refute Map.has_key?(Map.from_struct(machine.bus), :vram)
    refute Map.has_key?(Map.from_struct(machine.bus), :oam)

    machine = step(machine, 6)
    assert machine.cpu.pc == 0x015A
    assert Bus.read(machine.bus, 0x8000) == 0xFF
    assert Bus.read(machine.bus, 0xFF47) == 0xE4

    assert {:ok, machine, 0, startup_frame} = Machine.run_until_frame(machine)
    assert startup_frame == :binary.copy(<<0>>, 160 * 144)
    assert machine.bus.ppu.lcd_frame_state == :suppressed

    assert {:ok, machine, 1, frame} = Machine.run_until_frame(machine)
    assert byte_size(frame) == 160 * 144
    assert PPU.frame(machine.bus.ppu) == frame
    assert binary_part(frame, 0, 160) == :binary.copy(<<1>>, 160)
  end

  test "normal and double-speed CPUs advance the LCD through the same base-dot frame" do
    {:ok, normal} = Machine.load(rom())
    normal_bus = Bus.idle(normal.bus, div(@frame_dots, 4))

    {:ok, double} = Machine.load(rom(), model: :cgb)
    double_bus = double.bus |> Bus.write(0xFF4D, 1) |> then(&elem(Bus.stop(&1), 1))
    assert Bus.double_speed?(double_bus)
    double_bus = Bus.idle(double_bus, div(@frame_dots, 2))

    assert normal_bus.ppu.frame_number == 1
    assert double_bus.ppu.frame_number == 1
    assert {PPU.ly(normal_bus.ppu), PPU.dot(normal_bus.ppu)} == {0, 0}
    assert {PPU.ly(double_bus.ppu), PPU.dot(double_bus.ppu)} == {0, 0}
    assert normal_bus.divider != double_bus.divider
  end

  test "PPU STAT and VBlank signals become CPU-visible IF requests" do
    {:ok, machine} = Machine.load(rom())

    bus =
      machine.bus
      |> Bus.write(0xFF0F, 0)
      |> Bus.write(0xFF41, 0x08)
      |> Bus.idle(63)

    assert (bus.interrupt_flags &&& 0x02) != 0
    assert PPU.mode(bus.ppu) == 0

    bus =
      bus
      |> Bus.write(0xFF0F, 0)
      |> Bus.idle(div(144 * 456 - 252, 4))

    assert PPU.ly(bus.ppu) == 144
    assert (bus.interrupt_flags &&& 0x01) != 0
  end

  test "boot-ROM execution is explicit and distinct from post-boot initialization" do
    assert {:error, :boot_rom_required} = Machine.load(rom(), skip_boot: false)

    assert {:ok, machine} =
             Machine.load(rom(), skip_boot: false, boot_rom: :binary.copy(<<0x00>>, 0x100))

    assert machine.cpu.pc == 0
    assert machine.bus.boot_enabled
    assert Bus.read(machine.bus, 0) == 0
    assert Bus.read(machine.bus, 0xFF40) == 0
  end

  test "selects cartridge-compatible models and rejects a CGB-only downgrade" do
    assert {:ok, %{model: :dmg}} = Machine.load(rom(0x00))
    assert {:ok, %{model: :cgb}} = Machine.load(rom(0x80))
    assert {:ok, %{model: :cgb}} = Machine.load(rom(0xC0))
    assert {:ok, %{model: :dmg}} = Machine.load(rom(0x80), model: :dmg)
    assert {:ok, %{model: :dmg}} = Machine.load(rom(0x00), model: :dmg)
    assert {:error, :cgb_required} = Machine.load(rom(0xC0), model: :dmg)
  end

  test "boot skipping exposes documented DMG and CGB handoff state" do
    assert {:ok, dmg} = Machine.load(rom(0x00))
    assert dmg.cpu.f == 0xB0
    assert Bus.read(dmg.bus, 0xFF00) == 0xCF
    assert Bus.read(dmg.bus, 0xFF02) == 0x7E
    assert Bus.read(dmg.bus, 0xFF0F) == 0xE1
    assert Bus.read(dmg.bus, 0xFF40) == 0x91
    assert Bus.read(dmg.bus, 0xFF47) == 0xFC
    assert Bus.read(dmg.bus, 0xFF48) == 0xFF
    assert Bus.read(dmg.bus, 0xFF49) == 0xFF
    assert Bus.read(dmg.bus, 0xFF46) == 0xFF
    assert Bus.read(dmg.bus, 0xFF70) == 0xFF

    assert {:ok, zero_checksum} = Machine.load(rom_with_zero_header_checksum())
    assert zero_checksum.cpu.f == 0x80

    assert {:ok, cgb} = Machine.load(rom(0x80))

    assert {cgb.cpu.a, cgb.cpu.f, cgb.cpu.b, cgb.cpu.d, cgb.cpu.e} ==
             {0x11, 0x80, 0, 0xFF, 0x56}

    assert Bus.read(cgb.bus, 0xFF00) == 0xCF
    assert Bus.read(cgb.bus, 0xFF02) == 0x7F
    assert Bus.read(cgb.bus, 0xFF4D) == 0x7E
    assert Bus.read(cgb.bus, 0xFF4F) == 0xFE
    assert Bus.read(cgb.bus, 0xFF46) == 0x00
    assert Enum.map(0xFF51..0xFF55, &Bus.read(cgb.bus, &1)) == List.duplicate(0xFF, 5)
    assert {Bus.read(cgb.bus, 0xFF68), Bus.read(cgb.bus, 0xFF69)} == {0, 0xFF}
    assert {Bus.read(cgb.bus, 0xFF6A), Bus.read(cgb.bus, 0xFF6B)} == {0, 0xFF}
    assert Bus.read(cgb.bus, 0xFF70) == 0xF8
    assert elem(cgb.bus.ppu.color_ram, 0) == :binary.copy(<<0xFF>>, 64)
    assert elem(cgb.bus.ppu.color_ram, 1) == :binary.copy(<<0xFF>>, 64)

    bank_zero = Bus.write(cgb.bus, 0xD123, 0xA5)
    assert Bus.read(bank_zero, 0xD123) == 0xA5
    assert Bus.read(Bus.write(bank_zero, 0xFF70, 1), 0xD123) == 0xA5

    assert {:ok, compatibility} = Machine.load(rom(0), model: :cgb)

    assert {compatibility.cpu.a, compatibility.cpu.b, compatibility.cpu.d, compatibility.cpu.e,
            compatibility.cpu.h, compatibility.cpu.l} ==
             {0x11, 0, 0, 0x08, 0, 0x7C}

    licensed = rom(0) |> put_byte(0x14B, 0x01) |> with_checksum()
    expected_b = licensed |> binary_part(0x134, 16) |> :binary.bin_to_list() |> Enum.sum()
    expected_b = expected_b &&& 0xFF
    assert {:ok, licensed_compatibility} = Machine.load(licensed, model: :cgb)
    assert licensed_compatibility.cpu.b == expected_b

    expected_hl = if expected_b in [0x43, 0x58], do: {0x99, 0x1A}, else: {0, 0x7C}
    assert {licensed_compatibility.cpu.h, licensed_compatibility.cpu.l} == expected_hl
  end

  test "CPU-triggered OAM DMA stalls and delivers sprite attributes" do
    sprite_page = <<32, 40, 1, 0>> <> :binary.copy(<<0>>, 0x9C)
    program = <<0x3E, 0x02, 0xE0, 0x46, 0x18, 0xFE>>
    assert {:ok, machine} = Machine.load(dma_rom(program, sprite_page, 0))

    {machine, 2} = Machine.step(machine)
    {machine, 163} = Machine.step(machine)

    assert binary_part(machine.bus.ppu.oam, 0, 4) == <<32, 40, 1, 0>>
    assert machine.bus.oam_dma == nil
  end

  test "CPU-triggered CGB general DMA targets the CPU-selected VRAM bank" do
    tile = for(value <- 0x90..0x9F, into: <<>>, do: <<value>>)

    program = <<
      0x3E,
      0x01,
      0xE0,
      0x4F,
      0x3E,
      0x02,
      0xE0,
      0x51,
      0xAF,
      0xE0,
      0x52,
      0xE0,
      0x53,
      0xE0,
      0x54,
      0xE0,
      0x55,
      0x18,
      0xFE
    >>

    assert {:ok, machine} = Machine.load(dma_rom(program, tile, 0x80), model: :cgb)
    machine = step(machine, 8)
    {machine, 11} = Machine.step(machine)

    bank_one = Bus.write(machine.bus, 0xFF40, 0)
    assert for(address <- 0x8000..0x800F, into: <<>>, do: <<Bus.read(bank_one, address)>>) == tile

    bank_zero = Bus.write(bank_one, 0xFF4F, 0)

    assert for(address <- 0x8000..0x800F, into: <<>>, do: <<Bus.read(bank_zero, address)>>) ==
             :binary.copy(<<0>>, 16)
  end

  defp step(machine, 0), do: machine

  defp step(machine, count) do
    {machine, _m_cycles} = Machine.step(machine)
    step(machine, count - 1)
  end

  defp rom(cgb_flag \\ 0) do
    program = <<
      0x21,
      0x00,
      0x80,
      0x3E,
      0xFF,
      0x77,
      0x3E,
      0xE4,
      0xE0,
      0x47,
      0x18,
      0xFE
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0xC3, 0x50, 0x01>>)
    |> put_bytes(0x134, "MACHINE TEST" <> :binary.copy(<<0>>, 4))
    |> put_byte(0x143, cgb_flag)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> put_bytes(0x150, program)
    |> with_checksum()
  end

  defp dma_rom(program, source_page, cgb_flag) do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, program)
    |> put_bytes(0x134, "DMA TEST" <> :binary.copy(<<0>>, 8))
    |> put_byte(0x143, cgb_flag)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> put_bytes(0x200, source_page)
    |> with_checksum()
  end

  defp rom_with_zero_header_checksum do
    image = rom(0)
    checksum = :binary.at(image, 0x14D)
    version = :binary.at(image, 0x14C)

    image
    |> put_byte(0x14C, version + checksum &&& 0xFF)
    |> with_checksum()
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
