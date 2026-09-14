defmodule Beamicom.SNES.CPUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.Machine
  alias Beamicom.SNESTestROM

  test "resets in emulation mode through the mapped reset vector" do
    assert {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, reset: 0x8123))
    assert machine.cpu.pc == 0x8123
    assert machine.cpu.pb == 0
    assert machine.cpu.s == 0x01FF
    assert machine.cpu.emulation?
    assert (machine.cpu.p &&& 0x30) == 0x30
  end

  test "enters native mode, changes widths, and loads a 16-bit accumulator" do
    program = <<0x18, 0xFB, 0xC2, 0x30, 0xA9, 0x34, 0x12, 0xEA>>
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: program))

    assert {:ok, machine, 14} = Machine.step(machine)
    assert {:ok, machine, 14} = Machine.step(machine)
    refute machine.cpu.emulation?
    assert (machine.cpu.p &&& 0x01) == 1

    assert {:ok, machine, 22} = Machine.step(machine)
    assert (machine.cpu.p &&& 0x30) == 0

    assert {:ok, machine, 24} = Machine.step(machine)
    assert machine.cpu.a == 0x1234

    assert {:ok, machine, 14} = Machine.step(machine)
    assert machine.cpu.instructions == 5
    assert machine.cpu.master_clocks == 88
    assert machine.bus.timing.master_clocks == 88
  end

  test "uses the data bank for stores and preserves the accumulator high byte in 8-bit mode" do
    program = <<0xA9, 0x7F, 0x8D, 0x34, 0x12>>
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: program))
    machine = put_in(machine.cpu.a, 0xAB00)

    assert {:ok, machine, 16} = Machine.step(machine)
    assert machine.cpu.a == 0xAB7F
    assert {:ok, machine, 32} = Machine.step(machine)
    assert Beamicom.SNES.Bus.peek(machine.bus, 0x001234) == 0x7F
  end

  test "fails explicitly at an unsupported opcode" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0x02>>))

    assert {:error, {{:unsupported_opcode, 0x02}, 0x008000}, machine} =
             Machine.step(machine)

    assert machine.cpu.pc == 0x8001
    assert machine.bus.timing.master_clocks == 8
  end

  test "runs a tight loop to a PPU frame and drains synchronized audio" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0x80, 0xFE>>))

    assert {:ok, machine, frame} = Machine.run_until_frame(machine)
    assert frame.number == 0
    assert frame.width == 256
    assert frame.height == 224
    assert byte_size(frame.data) == 256 * 224 * 3
    assert machine.bus.timing.master_clocks == 225 * 1364

    assert {457, pcm, machine} = Machine.take_audio_pcm(machine)
    assert byte_size(pcm) == 457 * 4
    assert machine.bus.apu.pending_frames == 0
  end

  test "MVN copies A plus one bytes and updates the data bank" do
    {:ok, machine} =
      Machine.load(SNESTestROM.build(:lorom, program: <<0x54, 0x7E, 0x7F, 0xEA>>))

    {bus, 8} = Beamicom.SNES.Bus.write(machine.bus, 0x7F0010, 0xAA)
    {bus, 8} = Beamicom.SNES.Bus.write(bus, 0x7F0011, 0xBB)
    machine = %{machine | cpu: %{machine.cpu | a: 1, x: 0x10, y: 0x20}, bus: bus}

    assert {:ok, machine, _clocks} = Machine.step(machine)
    assert machine.cpu.pc == 0x8000
    assert {:ok, machine, _clocks} = Machine.step(machine)
    assert machine.cpu.pc == 0x8003
    assert machine.cpu.a == 0xFFFF
    assert machine.cpu.x == 0x12
    assert machine.cpu.y == 0x22
    assert machine.cpu.db == 0x7E
    assert Beamicom.SNES.Bus.peek(machine.bus, 0x7E0020) == 0xAA
    assert Beamicom.SNES.Bus.peek(machine.bus, 0x7E0021) == 0xBB
  end
end
