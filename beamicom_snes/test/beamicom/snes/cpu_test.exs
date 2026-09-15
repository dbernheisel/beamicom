defmodule Beamicom.SNES.CPUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{CPU, Machine}
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

  test "WDM consumes its signature byte" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0x42, 0xDB, 0xEA>>))

    assert {:ok, machine, 16} = Machine.step(machine)
    assert machine.cpu.pc == 0x8002

    assert {:ok, machine, 14} = Machine.step(machine)
    assert machine.cpu.pc == 0x8003
  end

  test "WAI idles until an interrupt and a masked IRQ still wakes it" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0xCB, 0xEA>>))

    assert {:ok, machine, 20} = Machine.step(machine)
    assert machine.cpu.waiting?
    assert machine.cpu.pc == 0x8001

    assert {:ok, machine, 6} = Machine.step(machine)
    assert machine.cpu.waiting?
    assert machine.cpu.pc == 0x8001

    machine = put_in(machine.bus.irq_flag?, true)
    assert {:ok, machine, 14} = Machine.step(machine)
    refute machine.cpu.waiting?
    assert machine.cpu.pc == 0x8002
    assert machine.bus.irq_flag?
  end

  test "STP enters an explicit stopped state" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0xDB>>))

    assert {:ok, machine, 20} = Machine.step(machine)
    assert machine.cpu.stopped?
    assert {:error, :cpu_stopped, machine} = Machine.step(machine)
    assert machine.cpu.pc == 0x8001
  end

  test "deferred execution batches a stable direct-page NMI polling loop" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0xA5, 0x10, 0xF0, 0xFC>>))

    assert {:ok, cpu, bus} = CPU.step_deferred(machine.cpu, machine.bus)
    assert {:ok, cpu, bus} = CPU.step_deferred(cpu, bus)
    assert cpu.pc == 0x8000
    assert cpu.instructions == 2

    assert {:ok, cpu, bus} = CPU.step_deferred(cpu, bus)
    assert cpu.pc == 0x8000
    assert cpu.instructions > 2
    assert Beamicom.SNES.Bus.cpu_master_clocks(bus) <= 1364

    bus = %{bus | wram: :array.set(0x10, 1, bus.wram)}
    assert {:ok, cpu, _bus} = CPU.step_deferred(cpu, bus)
    assert cpu.pc == 0x8002
    assert (cpu.a &&& 0xFF) == 1
  end

  test "deferred polling stops at an enabled H IRQ boundary" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0xA5, 0x10, 0xF0, 0xFC>>))
    bus = %{machine.bus | irq_mode: :h, htime: 100}

    {cpu, bus} =
      Enum.reduce_while(1..10, {machine.cpu, bus}, fn _, {cpu, bus} ->
        assert {:ok, cpu, bus} = CPU.step_deferred(cpu, bus)

        if bus.irq_flag?,
          do: {:halt, {cpu, bus}},
          else: {:cont, {cpu, bus}}
      end)

    assert bus.irq_flag?
    assert bus.timing.hclock >= 400
    assert bus.timing.hclock < 446
    assert cpu.instructions > 4
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

  test "decimal ADC and SBC exhaustively handle valid packed BCD bytes" do
    valid_bcd = for tens <- 0..9, ones <- 0..9, do: tens <<< 4 ||| ones

    for {opcode, operation} <- [{0x65, :add}, {0xE5, :subtract}] do
      {:ok, machine} =
        Machine.load(SNESTestROM.build(:lorom, program: <<opcode, 0x00>>))

      for right <- valid_bcd do
        bus = %{machine.bus | wram: :array.set(0, right, machine.bus.wram)}

        for left <- valid_bcd, carry <- [0, 1] do
          p = 0x3C ||| carry
          cpu = %{machine.cpu | a: 0xA500 ||| left, p: p, pc: 0x8000}
          assert {:ok, cpu, _bus} = CPU.step_deferred(cpu, bus)

          {expected, expected_carry?} = decimal_result(operation, left, right, carry, 100)
          expected_flags = result_flags(expected, expected_carry?, 0x80)

          assert {cpu.a, cpu.p &&& 0x83} == {0xA500 ||| expected, expected_flags},
                 "#{operation} #{hex(left, 2)} #{hex(right, 2)} carry=#{carry}"
        end
      end
    end
  end

  test "decimal ADC and SBC produce 65C816 overflow flags" do
    cases = [
      {0x69, 8, 0x49, 0x50, 0, 0x99, 0xC0},
      {0x69, 8, 0x79, 0x00, 1, 0x80, 0xC0},
      {0x69, 8, 0x50, 0x50, 0, 0x00, 0x43},
      {0x69, 8, 0x99, 0x00, 1, 0x00, 0x03},
      {0xE9, 8, 0x80, 0x01, 1, 0x79, 0x41},
      {0xE9, 8, 0x00, 0x01, 1, 0x99, 0x80},
      {0xE9, 8, 0x50, 0x50, 1, 0x00, 0x03},
      {0x69, 16, 0x4999, 0x5000, 0, 0x9999, 0xC0},
      {0x69, 16, 0x9999, 0x0001, 0, 0x0000, 0x03},
      {0xE9, 16, 0x8000, 0x0001, 1, 0x7999, 0x41},
      {0xE9, 16, 0x0000, 0x0001, 1, 0x9999, 0x80}
    ]

    for {opcode, width, left, right, carry, expected, flags} <- cases do
      cpu = run_decimal_immediate(opcode, width, left, right, carry)
      mask = if width == 8, do: 0xFF, else: 0xFFFF
      assert (cpu.a &&& mask) == expected
      assert (cpu.p &&& 0xC3) == flags
    end
  end

  test "TCS forces the stack high byte to page one in emulation mode" do
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<0x1B>>))
    machine = put_in(machine.cpu.a, 0xAB34)

    assert {:ok, machine, 14} = Machine.step(machine)
    assert machine.cpu.s == 0x0134

    machine = %{
      machine
      | cpu: %{machine.cpu | a: 0xCD56, emulation?: false, p: 0, pc: 0x8000}
    }

    assert {:ok, machine, 14} = Machine.step(machine)
    assert machine.cpu.s == 0xCD56
  end

  defp run_decimal_immediate(opcode, width, left, right, carry) do
    operand = if width == 8, do: <<right>>, else: <<right::little-16>>
    {:ok, machine} = Machine.load(SNESTestROM.build(:lorom, program: <<opcode>> <> operand))

    {emulation?, p, a} =
      if width == 8,
        do: {true, 0x3C ||| carry, 0xA500 ||| left},
        else: {false, 0x08 ||| carry, left}

    machine = %{machine | cpu: %{machine.cpu | a: a, p: p, emulation?: emulation?}}
    assert {:ok, machine, _clocks} = Machine.step(machine)
    machine.cpu
  end

  defp decimal_result(:add, left, right, carry, modulus) do
    result = bcd_to_integer(left) + bcd_to_integer(right) + carry
    {integer_to_bcd(Integer.mod(result, modulus)), result >= modulus}
  end

  defp decimal_result(:subtract, left, right, carry, modulus) do
    result = bcd_to_integer(left) - bcd_to_integer(right) - (1 - carry)
    {integer_to_bcd(Integer.mod(result, modulus)), result >= 0}
  end

  defp bcd_to_integer(value), do: (value >>> 4) * 10 + (value &&& 0x0F)
  defp integer_to_bcd(value), do: div(value, 10) <<< 4 ||| rem(value, 10)

  defp result_flags(result, carry?, sign) do
    if(carry?, do: 0x01, else: 0) |||
      if(result == 0, do: 0x02, else: 0) |||
      if((result &&& sign) != 0, do: 0x80, else: 0)
  end

  defp hex(value, bytes),
    do: value |> Integer.to_string(16) |> String.pad_leading(bytes, "0")
end
