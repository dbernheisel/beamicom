defmodule Beamicom.GBA.CPUTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Bus, CPU, Cartridge, Machine, TestROM}

  test "executes scalar ARM data processing and stores through the bus" do
    program =
      <<
        0xE3A0_0001::little-32,
        0xE280_1002::little-32,
        0xE3A0_2402::little-32,
        0xE582_1000::little-32,
        0xEAFF_FFFE::little-32
      >>

    {cpu, bus} = machine_parts(program)
    {:ok, cpu, bus, _cycles} = step(cpu, bus, 4)

    assert CPU.register(cpu, 0) == 1
    assert CPU.register(cpu, 1) == 3
    assert CPU.register(cpu, 2) == 0x0200_0000
    assert Bus.peek32(bus, 0x0200_0000) == 3
    assert CPU.register(cpu, 15) == 0x0800_0010
  end

  test "honors condition flags and branches with pipeline-relative offsets" do
    program =
      <<
        0xE3A0_0001::little-32,
        0xE350_0001::little-32,
        0x1A00_0000::little-32,
        0xE3A0_1007::little-32,
        0xEAFF_FFFE::little-32
      >>

    {cpu, bus} = machine_parts(program)
    {:ok, cpu, _bus, _cycles} = step(cpu, bus, 4)
    assert CPU.register(cpu, 1) == 7
    assert CPU.register(cpu, 15) == 0x0800_0010
  end

  test "exchanges into Thumb and executes immediate and memory instructions" do
    program =
      <<
        0xE12F_FF10::little-32,
        0x2005::little-16,
        0x3003::little-16,
        0x6008::little-16,
        0xE7FE::little-16
      >>

    {cpu, bus} = machine_parts(program)

    cpu =
      cpu
      |> CPU.put_register(0, 0x0800_0005)
      |> CPU.put_register(1, 0x0200_0000)

    {:ok, cpu, bus, _cycles} = step(cpu, bus, 4)

    assert CPU.thumb?(cpu)
    assert CPU.register(cpu, 0) == 8
    assert Bus.peek32(bus, 0x0200_0000) == 8
    assert CPU.register(cpu, 15) == 0x0800_000A
  end

  test "pushes and pops Thumb register lists in architectural order" do
    program =
      <<
        0xB503::little-16,
        0x2000::little-16,
        0x2100::little-16,
        0xBD03::little-16
      >>

    {cpu, bus} = machine_parts(program)

    cpu =
      cpu
      |> CPU.put_cpsr(0x3F)
      |> CPU.put_register(0, 0x11)
      |> CPU.put_register(1, 0x22)
      |> CPU.put_register(13, 0x0300_7F00)
      |> CPU.put_register(14, 0x0800_0101)

    {:ok, cpu, bus, _cycles} = step(cpu, bus, 4)

    assert CPU.register(cpu, 0) == 0x11
    assert CPU.register(cpu, 1) == 0x22
    assert CPU.register(cpu, 13) == 0x0300_7F00
    assert CPU.register(cpu, 15) == 0x0800_0100
    assert Bus.peek32(bus, 0x0300_7EF4) == 0x11
    assert Bus.peek32(bus, 0x0300_7EF8) == 0x22
    assert Bus.peek32(bus, 0x0300_7EFC) == 0x0800_0101
  end

  test "banks stack pointers while switching processor modes" do
    cpu =
      CPU.post_boot()
      |> CPU.put_register(8, 0x88)
      |> CPU.put_register(13, 0x0300_7E00)

    assert {:ok, irq_cpu} = CPU.write_cpsr(cpu, 0x12)
    assert CPU.mode(irq_cpu) == :irq
    assert CPU.register(irq_cpu, 8) == 0x88
    assert CPU.register(irq_cpu, 13) == 0x0300_7FA0

    irq_cpu =
      irq_cpu
      |> CPU.put_register(8, 0x99)
      |> CPU.put_register(13, 0x0300_7D00)

    assert {:ok, system_cpu} = CPU.write_cpsr(irq_cpu, 0x1F)
    assert CPU.mode(system_cpu) == :system
    assert CPU.register(system_cpu, 8) == 0x99
    assert CPU.register(system_cpu, 13) == 0x0300_7E00

    assert {:ok, irq_cpu} = CPU.write_cpsr(system_cpu, 0x12)
    assert CPU.register(irq_cpu, 13) == 0x0300_7D00
  end

  test "executes ARM status register transfers used by cartridge startup" do
    program =
      <<
        0xE3A0_0012::little-32,
        0xE129_F000::little-32,
        0xE10F_1000::little-32,
        0xE3A0_001F::little-32,
        0xE129_F000::little-32
      >>

    {cpu, bus} = machine_parts(program)
    {:ok, cpu, _bus, _cycles} = step(cpu, bus, 5)

    assert CPU.register(cpu, 1) == 0x12
    assert CPU.mode(cpu) == :system
    assert CPU.register(cpu, 13) == 0x0300_7F00
  end

  test "restricts user-mode MSR writes to the CPSR flags field" do
    program =
      <<
        0xE129_F000::little-32,
        0xE10F_1000::little-32
      >>

    {cpu, bus} = machine_parts(program)

    cpu =
      cpu
      |> CPU.put_cpsr(0x10)
      |> CPU.put_register(0, 0xA000_0012)

    {:ok, cpu, _bus, _cycles} = step(cpu, bus, 2)

    assert CPU.register(cpu, 1) == 0xA000_0010
    assert CPU.mode(cpu) == :user
  end

  test "enters IRQ through the HLE BIOS trampoline and restores CPSR" do
    assert {:ok, machine} = Beamicom.GBA.Machine.load(TestROM.build(<<0xE12F_FF1E::little-32>>))
    {bus, 1} = Bus.write32(machine.bus, 0x0300_7FFC, 0x0800_0000)
    bus = %{bus | interrupt_enable: 1, interrupt_flags: 1, interrupt_master_enable: 1}

    assert {:ok, irq_cpu, bus, 0} = CPU.step(machine.cpu, bus)
    assert CPU.mode(irq_cpu) == :irq
    assert CPU.register(irq_cpu, 15) == 0x18
    assert {:ok, 0x1F} = CPU.fetch_spsr(irq_cpu)

    assert {:ok, cpu, _bus, _cycles} = step(irq_cpu, bus, 8)
    assert CPU.mode(cpu) == :system
    assert CPU.register(cpu, 15) == 0x0800_0000
    assert CPU.register(cpu, 13) == 0x0300_7F00
  end

  test "implements BIOS CpuFastSet word copies" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    {bus, 1} = Bus.write32(bus, 0x0300_0000, 0x1122_3344)
    {bus, 1} = Bus.write32(bus, 0x0300_0004, 0x5566_7788)
    {bus, _cycles} = Bus.write32(bus, 0x0200_001C, 0xFFFF_FFFF)

    cpu =
      cpu
      |> CPU.put_register(0, 0x0300_0000)
      |> CPU.put_register(1, 0x0200_0000)
      |> CPU.put_register(2, 2)

    assert {:ok, copied_cpu, bus, _cycles} = CPU.software_interrupt(cpu, bus, 0x0C)
    assert Bus.peek32(bus, 0x0200_0000) == 0x1122_3344
    assert Bus.peek32(bus, 0x0200_0004) == 0x5566_7788
    assert Bus.peek32(bus, 0x0200_001C) == 0
    assert CPU.register(copied_cpu, 0) == 0x0300_0020
    assert CPU.register(copied_cpu, 1) == 0x0200_0020
    assert CPU.register(copied_cpu, 2) == 2
  end

  test "implements BIOS signed division variants" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)

    div_cpu =
      cpu
      |> CPU.put_register(0, 0xFFFF_FB2E)
      |> CPU.put_register(1, 10)

    assert {:ok, div_cpu, ^bus, 0} = CPU.software_interrupt(div_cpu, bus, 6)
    assert CPU.register(div_cpu, 0) == 0xFFFF_FF85
    assert CPU.register(div_cpu, 1) == 0xFFFF_FFFC
    assert CPU.register(div_cpu, 3) == 123

    div_arm_cpu =
      cpu
      |> CPU.put_register(0, 10)
      |> CPU.put_register(1, 0xFFFF_FB2E)

    assert {:ok, div_arm_cpu, ^bus, 0} = CPU.software_interrupt(div_arm_cpu, bus, 7)
    assert CPU.register(div_arm_cpu, 0) == 0xFFFF_FF85
    assert CPU.register(div_arm_cpu, 1) == 0xFFFF_FFFC
    assert CPU.register(div_arm_cpu, 3) == 123

    zero_cpu = CPU.put_register(cpu, 1, 0)
    assert {:error, :division_by_zero, ^zero_cpu, ^bus} = CPU.software_interrupt(zero_cpu, bus, 6)
  end

  test "implements BIOS fixed-point ArcTan and ArcTan2" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)

    arc_tan_cpu = CPU.put_register(cpu, 0, 0x4000)
    assert {:ok, arc_tan_cpu, ^bus, 0} = CPU.software_interrupt(arc_tan_cpu, bus, 9)
    assert CPU.register(arc_tan_cpu, 0) == 0x2000
    assert CPU.register(arc_tan_cpu, 1) == 0xFFFF_C000
    assert CPU.register(arc_tan_cpu, 3) == 0x8000

    for {x, y, expected} <- [
          {1, 0, 0x0000},
          {0, 1, 0x4000},
          {0xFFFF_FFFF, 0, 0x8000},
          {0, 0xFFFF_FFFF, 0xC000},
          {1, 1, 0x2000},
          {0xFFFF_FFFF, 1, 0x6000},
          {0xFFFF_FFFF, 0xFFFF_FFFF, 0xA000},
          {1, 0xFFFF_FFFF, 0xE000}
        ] do
      arc_tan2_cpu = cpu |> CPU.put_register(0, x) |> CPU.put_register(1, y)

      assert {:ok, arc_tan2_cpu, ^bus, 0} =
               CPU.software_interrupt(arc_tan2_cpu, bus, 0x0A)

      assert CPU.register(arc_tan2_cpu, 0) == expected
      expected_r1 = if x == 0 or y == 0, do: y, else: 0xFFFF_C000
      assert CPU.register(arc_tan2_cpu, 1) == expected_r1
      assert CPU.register(arc_tan2_cpu, 3) == 0x170
    end
  end

  test "implements BIOS background affine parameter generation" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    source = 0x0300_0000
    destination = 0x0200_0000

    bus =
      bus
      |> put32(source, 100 * 256)
      |> put32(source + 4, 200 * 256)
      |> put16(source + 8, 10)
      |> put16(source + 10, 20)
      |> put16(source + 12, 0x0100)
      |> put16(source + 14, 0x0100)
      |> put16(source + 16, 0)

    cpu =
      cpu
      |> CPU.put_register(0, source)
      |> CPU.put_register(1, destination)
      |> CPU.put_register(2, 1)
      |> CPU.put_register(3, 0xDEAD_BEEF)

    assert {:ok, affine_cpu, bus, _cycles} = CPU.software_interrupt(cpu, bus, 0x0E)
    assert Bus.peek16(bus, destination) == 0x0100
    assert Bus.peek16(bus, destination + 2) == 0
    assert Bus.peek16(bus, destination + 4) == 0
    assert Bus.peek16(bus, destination + 6) == 0x0100
    assert Bus.peek32(bus, destination + 8) == 90 * 256
    assert Bus.peek32(bus, destination + 12) == 180 * 256
    assert CPU.register(affine_cpu, 0) == source + 20
    assert CPU.register(affine_cpu, 1) == destination + 16
    assert CPU.register(affine_cpu, 2) == 1
    assert CPU.register(affine_cpu, 3) == 0
  end

  test "implements BIOS object affine parameter generation with a byte stride" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    source = 0x0300_0000
    destination = 0x0200_0000

    bus =
      bus
      |> put16(source, 0x0100)
      |> put16(source + 2, 0x0080)
      |> put16(source + 4, 0x4000)

    cpu =
      cpu
      |> CPU.put_register(0, source)
      |> CPU.put_register(1, destination)
      |> CPU.put_register(2, 1)
      |> CPU.put_register(3, 8)

    assert {:ok, affine_cpu, bus, _cycles} = CPU.software_interrupt(cpu, bus, 0x0F)
    assert Bus.peek16(bus, destination) == 0
    assert Bus.peek16(bus, destination + 8) == 0xFF00
    assert Bus.peek16(bus, destination + 16) == 0x0080
    assert Bus.peek16(bus, destination + 24) == 0
    assert CPU.register(affine_cpu, 0) == source + 8
    assert CPU.register(affine_cpu, 1) == destination + 32
    assert CPU.register(affine_cpu, 2) == 1
    assert CPU.register(affine_cpu, 3) == 8
  end

  test "implements BIOS integer square root" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)

    cpu = CPU.put_register(cpu, 0, 2)
    assert {:ok, cpu, ^bus, 0} = CPU.software_interrupt(cpu, bus, 8)
    assert CPU.register(cpu, 0) == 1

    cpu = CPU.put_register(cpu, 0, 0xFFFF_FFFF)
    assert {:ok, cpu, ^bus, 0} = CPU.software_interrupt(cpu, bus, 8)
    assert CPU.register(cpu, 0) == 65_535
  end

  test "implements BIOS LZ77 expansion with overlapping backreferences" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    compressed = <<0x10, 9, 0, 0, 0x10, ?A, ?B, ?C, 0x30, 0x02>>

    bus =
      compressed
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(bus, fn {byte, index}, bus ->
        {bus, _cycles} = Bus.write8(bus, 0x0300_0000 + index, byte)
        bus
      end)

    cpu =
      cpu
      |> CPU.put_register(0, 0x0300_0000)
      |> CPU.put_register(1, 0x0200_0000)

    assert {:ok, ^cpu, bus, _cycles} = CPU.software_interrupt(cpu, bus, 0x11)

    output = for index <- 0..8, into: <<>>, do: <<Bus.peek8(bus, 0x0200_0000 + index)>>
    assert output == "ABCABCABC"
  end

  test "implements BIOS RegisterRamReset memory groups and forced blank" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    {bus, 3} = Bus.write8(bus, 0x0200_0000, 0x11)
    {bus, 1} = Bus.write8(bus, 0x0300_0000, 0x22)
    {bus, 1} = Bus.write8(bus, 0x0300_7F10, 0x33)
    {bus, 1} = Bus.write16(bus, 0x0500_0000, 0x4444)
    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x5555)
    {bus, 1} = Bus.write16(bus, 0x0700_0000, 0x6666)
    {bus, 1} = Bus.write16(bus, 0x0400_0000, 0x0403)
    cpu = CPU.put_register(cpu, 0, 0x1F)

    assert {:ok, ^cpu, bus, 0} = CPU.software_interrupt(cpu, bus, 1)

    assert Bus.peek8(bus, 0x0200_0000) == 0
    assert Bus.peek8(bus, 0x0300_0000) == 0
    assert Bus.peek8(bus, 0x0300_7F10) == 0x33
    assert Bus.peek16(bus, 0x0500_0000) == 0
    assert Bus.peek16(bus, 0x0600_0000) == 0
    assert Bus.peek16(bus, 0x0700_0000) == 0
    assert Bus.peek16(bus, 0x0400_0000) == 0x0080
  end

  test "resets modeled IO groups through BIOS RegisterRamReset" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    {bus, 1} = Bus.write16(bus, 0x0400_0008, 0x1234)
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFF0)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080)
    {bus, 1} = Bus.write16(bus, 0x0400_0200, 0x3FFF)
    {bus, 1} = Bus.write16(bus, 0x0400_0208, 1)
    cpu = CPU.put_register(cpu, 0, 0x80)

    assert {:ok, ^cpu, bus, 0} = CPU.software_interrupt(cpu, bus, 1)

    assert Bus.peek16(bus, 0x0400_0000) == 0x0080
    assert Bus.peek16(bus, 0x0400_0008) == 0
    assert Bus.peek16(bus, 0x0400_0100) == 0
    assert Bus.peek16(bus, 0x0400_0102) == 0
    assert Bus.peek16(bus, 0x0400_0200) == 0
    assert Bus.peek16(bus, 0x0400_0208) == 0
  end

  test "implements BIOS IntrWait old-flag and discard behavior" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    bus = Bus.put8(bus, 0x0300_7FF8, 1)

    immediate_cpu = cpu |> CPU.put_register(0, 0) |> CPU.put_register(1, 1)

    assert {:ok, ^immediate_cpu, bus, 0} =
             CPU.software_interrupt(immediate_cpu, bus, 4)

    assert Bus.peek16(bus, 0x0300_7FF8) == 0
    assert Bus.peek16(bus, 0x0400_0208) == 1

    bus = Bus.put8(bus, 0x0300_7FF8, 1)
    wait_cpu = cpu |> CPU.put_register(0, 1) |> CPU.put_register(1, 1)

    assert {:ok, waiting_cpu, bus, 0} = CPU.software_interrupt(wait_cpu, bus, 4)
    assert waiting_cpu.run_state == {:interrupt_wait, 1}
    assert Bus.peek16(bus, 0x0300_7FF8) == 0

    bus = Bus.put8(bus, 0x0300_7FF8, 1)
    assert {:ok, resumed_cpu, bus, 0} = CPU.step(waiting_cpu, bus)
    assert resumed_cpu.run_state == :running
    assert Bus.peek16(bus, 0x0300_7FF8) == 0
  end

  test "implements BIOS VBlankIntrWait as a new VBlank wait" do
    {cpu, bus} = machine_parts(<<0xEAFF_FFFE::little-32>>)
    bus = Bus.put8(bus, 0x0300_7FF8, 1)

    assert {:ok, waiting_cpu, bus, 0} = CPU.software_interrupt(cpu, bus, 5)
    assert waiting_cpu.run_state == {:interrupt_wait, 1}
    assert Bus.peek16(bus, 0x0300_7FF8) == 0
    assert Bus.peek16(bus, 0x0400_0208) == 1
  end

  test "BIOS interrupt wait resumes only after servicing the requested IRQ" do
    assert {:ok, machine} = Machine.load(TestROM.build(<<0xE12F_FF1E::little-32>>))
    %{cpu: cpu, bus: bus} = machine
    {bus, 1} = Bus.write32(bus, 0x0300_7FFC, 0x0800_0000)
    assert {:ok, waiting_cpu, bus, 0} = CPU.software_interrupt(cpu, bus, 5)
    bus = %{bus | interrupt_enable: 1, interrupt_flags: 1, interrupt_master_enable: 1}

    assert {:ok, irq_cpu, ^bus, 0} = CPU.step(waiting_cpu, bus)
    assert irq_cpu.run_state == {:interrupt_wait_irq, 1, 0x0800_0000, 0x1F}
    assert CPU.mode(irq_cpu) == :irq
    assert CPU.register(irq_cpu, 15) == 0x18

    bus = bus |> Bus.put8(0x0300_7FF8, 1) |> Map.put(:interrupt_flags, 0)
    assert {:ok, returned_cpu, bus, _cycles} = step(irq_cpu, bus, 8)
    assert returned_cpu.run_state == irq_cpu.run_state
    assert CPU.mode(returned_cpu) == :system

    assert {:ok, resumed_cpu, _bus, 0} = CPU.step(returned_cpu, bus)
    assert resumed_cpu.run_state == :running
  end

  test "BIOS interrupt wait services unrelated IRQs and keeps waiting" do
    assert {:ok, machine} = Machine.load(TestROM.build(<<0xE12F_FF1E::little-32>>))
    %{cpu: cpu, bus: bus} = machine
    {bus, 1} = Bus.write32(bus, 0x0300_7FFC, 0x0800_0000)
    assert {:ok, waiting_cpu, bus, 0} = CPU.software_interrupt(cpu, bus, 5)
    bus = %{bus | interrupt_enable: 5, interrupt_flags: 4, interrupt_master_enable: 1}

    assert {:ok, irq_cpu, ^bus, 0} = CPU.step(waiting_cpu, bus)
    assert match?({:interrupt_wait_irq, 1, _, _}, irq_cpu.run_state)

    bus = bus |> Bus.put8(0x0300_7FF8, 4) |> Map.put(:interrupt_flags, 0)
    assert {:ok, returned_cpu, bus, _cycles} = step(irq_cpu, bus, 8)
    assert {:ok, still_waiting_cpu, _bus, cycles} = CPU.step(returned_cpu, bus)
    assert cycles > 0
    assert still_waiting_cpu.run_state == {:interrupt_wait, 1}
  end

  defp machine_parts(program) do
    {:ok, cartridge} = program |> TestROM.build() |> Cartridge.load()
    {CPU.post_boot(), Bus.new(cartridge)}
  end

  defp step(cpu, bus, count) do
    Enum.reduce(1..count, {:ok, cpu, bus, 0}, fn _index, {:ok, cpu, bus, cycles} ->
      {:ok, cpu, bus, step_cycles} = CPU.step(cpu, bus)
      {:ok, cpu, bus, cycles + step_cycles}
    end)
  end

  defp put16(bus, address, value) do
    {bus, _cycles} = Bus.write16(bus, address, value)
    bus
  end

  defp put32(bus, address, value) do
    {bus, _cycles} = Bus.write32(bus, address, value)
    bus
  end
end
