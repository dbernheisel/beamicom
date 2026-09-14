defmodule Beamicom.SNES.InterruptTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{Bus, Cartridge, Machine}
  alias Beamicom.SNESTestROM

  setup do
    {:ok, cartridge} = :lorom |> SNESTestROM.build() |> Cartridge.load()
    %{bus: Bus.new(cartridge)}
  end

  test "vblank latches RDNMI and conditionally raises an NMI edge", %{bus: bus} do
    bus = Bus.advance_master(bus, 225 * 1364)
    assert bus.nmi_flag?
    refute bus.nmi_pending?
    assert bus.ppu.frame_ready.number == 0

    {value, bus, 6} = Bus.read(bus, 0x004210)
    assert (value &&& 0x80) != 0
    refute bus.nmi_flag?

    {bus, 6} = Bus.write(Bus.new(bus.cartridge), 0x004200, 0x80)
    bus = Bus.advance_master(bus, 225 * 1364 - 6)
    assert bus.nmi_pending?
  end

  test "H and V timer modes assert and TIMEUP acknowledges the IRQ", %{bus: bus} do
    {bus, 6} = Bus.write(bus, 0x004207, 10)
    {bus, 6} = Bus.write(bus, 0x004208, 0)
    {bus, 6} = Bus.write(bus, 0x004200, 0x10)
    bus = Bus.advance_master(bus, 40 - bus.timing.hclock)
    assert Bus.irq_pending?(bus)

    {value, bus, 6} = Bus.read(bus, 0x004211)
    assert (value &&& 0x80) != 0
    refute Bus.irq_pending?(bus)

    {bus, 6} = Bus.write(Bus.new(bus.cartridge), 0x004209, 1)
    {bus, 6} = Bus.write(bus, 0x00420A, 0)
    {bus, 6} = Bus.write(bus, 0x004200, 0x20)
    bus = Bus.advance_master(bus, 1364 - bus.timing.hclock)
    assert bus.timing.vline == 1
    assert Bus.irq_pending?(bus)
  end

  test "the CPU enters an emulation-mode NMI and RTI restores execution" do
    rom =
      :lorom
      |> SNESTestROM.build(program: <<0xEA>>)
      |> SNESTestROM.put_bytes(0x7FFA, <<0x00, 0x90>>)
      |> SNESTestROM.put_byte(0x1000, 0x40)

    {:ok, machine} = Machine.load(rom)
    {bus, 6} = Bus.write(machine.bus, 0x004200, 0x80)
    bus = Bus.advance_master(bus, 225 * 1364 - 6)
    machine = %{machine | bus: bus}

    assert {:ok, machine, 52} = Machine.step(machine)
    assert machine.cpu.pc == 0x9000
    assert machine.cpu.pb == 0
    assert machine.cpu.s == 0x01FC
    assert (machine.cpu.p &&& 0x04) != 0

    assert {:ok, machine, 44} = Machine.step(machine)
    assert machine.cpu.pc == 0x8000
    assert machine.cpu.s == 0x01FF
  end
end
