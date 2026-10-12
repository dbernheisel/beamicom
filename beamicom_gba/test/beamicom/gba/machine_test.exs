defmodule Beamicom.GBA.MachineTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Bus, CPU, Machine, TestROM}
  alias Beamicom.GBA.PPU.ColorCorrection

  test "loads controlled skip-boot state and executes a complete frame" do
    assert {:ok, machine} = Machine.load(TestROM.build())
    assert CPU.register(machine.cpu, 15) == 0x0800_0000
    assert CPU.register(machine.cpu, 13) == 0x0300_7F00

    {bus, 1} = Bus.write16(machine.bus, 0x0400_0000, 0x0403)
    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x03E0)

    assert {:ok, machine, 0, frame, 738, pcm} =
             Machine.run_until_frame(%{machine | bus: bus})

    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x03E0)
    assert byte_size(pcm) == 738 * 4
    assert machine.bus.ppu.frame_number == 1
  end

  test "requires a user-supplied 16 KiB BIOS when boot execution is requested" do
    rom = TestROM.build()
    assert {:error, :bios_required} = Machine.load(rom, skip_boot: false)
    assert {:error, :bios_required} = Machine.load(rom, skip_boot: false, bios: <<0>>)

    assert {:ok, machine} =
             Machine.load(rom, skip_boot: false, bios: :binary.copy(<<0>>, 16 * 1024))

    assert CPU.register(machine.cpu, 15) == 0
    assert Bus.peek32(machine.bus, 0) == 0
  end

  test "validates CPU executor and decoded-block cache options" do
    rom = TestROM.build()

    assert {:ok, %{cpu_executor: :scalar}} = Machine.load(rom)

    assert {:ok, %{cpu_executor: :scalar}} = Machine.load(rom, cpu_executor: :scalar)

    assert {:ok, %{cpu_executor: :decoded_blocks}} =
             Machine.load(rom, cpu_executor: :decoded_blocks)

    assert {:error, {:invalid_cpu_executor, :jit}} =
             Machine.load(rom, cpu_executor: :jit)

    assert {:error, {:invalid_block_cache_limit, -1}} =
             Machine.load(rom, block_cache_limit: -1)
  end

  test "emits Direct Sound samples through the machine audio boundary" do
    assert {:ok, machine} = Machine.load(TestROM.build())
    {bus, _cycles} = Bus.write16(machine.bus, 0x0400_0082, 0x0304)
    {bus, _cycles} = Bus.write16(bus, 0x0400_0084, 0x0080)

    bus =
      Enum.reduce(1..8, bus, fn _, bus ->
        {bus, _cycles} = Bus.write32(bus, 0x0400_00A0, 0x4040_4040)
        bus
      end)

    {bus, _cycles} = Bus.write16(bus, 0x0400_0100, 0xFE00)
    {bus, _cycles} = Bus.write16(bus, 0x0400_0102, 0x0080)

    assert {:ok, _machine, 0, _frame, 738, pcm} =
             Machine.run_until_frame(%{machine | bus: bus})

    assert Enum.any?(:binary.bin_to_list(pcm), &(&1 != 0))
  end

  test "reports undefined instructions instead of silently approximating them" do
    rom = TestROM.build(<<0xEE00_0010::little-32>>)
    assert {:ok, machine} = Machine.load(rom)

    assert {:error, {:undefined_arm_instruction, 0xEE00_0010, 0x0800_0000}, _machine} =
             Machine.step(machine)
  end
end
