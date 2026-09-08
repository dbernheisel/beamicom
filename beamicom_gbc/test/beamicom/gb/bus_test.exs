defmodule Beamicom.GB.BusTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.Bus

  test "flat memory loads, reads, and writes bytes" do
    bus = Bus.new(<<0x12, 0x34>>) |> Bus.load(0xFFFE, <<0xAB, 0xCD>>)

    assert Bus.read(bus, 0) == 0x12
    assert Bus.read(bus, 1) == 0x34
    assert Bus.read(bus, 0x8000) == 0
    assert Bus.read(bus, 0xFFFE) == 0xAB
    assert Bus.read(bus, 0xFFFF) == 0xCD

    changed = Bus.write(bus, 0x8000, 0xEF)
    assert Bus.read(changed, 0x8000) == 0xEF
    assert Bus.read(bus, 0x8000) == 0
  end

  test "16-bit accesses are little endian and wrap at the address boundary" do
    bus = Bus.new() |> Bus.write16(0xFFFF, 0xBEEF)

    assert Bus.read(bus, 0xFFFF) == 0xEF
    assert Bus.read(bus, 0) == 0xBE
    assert Bus.read16(bus, 0xFFFF) == 0xBEEF
  end

  test "interrupt and timer registers are projected instead of duplicated in flat memory" do
    bus =
      Bus.new()
      |> Bus.write(0xFF0F, 0xFF)
      |> Bus.write(0xFFFF, 0xA5)
      |> Bus.write(0xFF05, 0x12)
      |> Bus.write(0xFF06, 0x34)
      |> Bus.write(0xFF07, 0xFF)

    assert Bus.read(bus, 0xFF0F) == 0xFF
    assert Bus.read(bus, 0xFFFF) == 0xA5
    assert Bus.read(bus, 0xFF05) == 0x12
    assert Bus.read(bus, 0xFF06) == 0x34
    assert Bus.read(bus, 0xFF07) == 0xFF
    assert Bus.pending_interrupts(bus) == 0x05
  end

  test "interrupt requests use literal masks and acknowledgement clears only its source" do
    bus =
      Bus.new()
      |> Bus.request_interrupt(:vblank)
      |> Bus.request_interrupt(:timer)
      |> Bus.request_interrupt(:joypad)

    assert Bus.read(bus, 0xFF0F) == 0xF5
    assert Bus.read(Bus.acknowledge_interrupt(bus, 0x04), 0xFF0F) == 0xF1
  end

  test "divider advances in exact T-cycles and disabled timer takes the batched path" do
    bus = Bus.tick(Bus.new(), 0x10104)
    assert bus.divider == 0x0104
    assert Bus.read(bus, 0xFF04) == 1
    assert bus.tima == 0

    bus = Bus.write(bus, 0xFF04, 0x99)
    assert bus.divider == 0
    assert Bus.read(bus, 0xFF04) == 0
  end

  test "each TAC clock selection increments TIMA on the selected falling edge" do
    for {select, period} <- [{0, 1024}, {1, 16}, {2, 64}, {3, 256}] do
      bus = Bus.new() |> Bus.write(0xFF07, 0x04 ||| select)
      bus = Bus.tick(bus, period - 1)
      assert bus.tima == 0, "TAC frequency #{select} incremented early"
      assert Bus.tick(bus, 1).tima == 1
    end
  end

  test "DIV reset and TAC changes honor timer-input falling-edge glitches" do
    high_bit_3 = Bus.tick(Bus.new(), 8)

    div_glitch = high_bit_3 |> Bus.write(0xFF07, 0x05) |> Bus.write(0xFF04, 0)
    assert div_glitch.tima == 1

    tac_glitch = high_bit_3 |> Bus.write(0xFF07, 0x05) |> Bus.write(0xFF07, 0)
    assert tac_glitch.tima == 1
  end

  test "TIMA overflow reloads TMA and requests IRQ four T-cycles later" do
    bus =
      Bus.new()
      |> Bus.write(0xFF05, 0xFF)
      |> Bus.write(0xFF06, 0xA7)
      |> Bus.write(0xFF07, 0x05)
      |> Bus.tick(16)

    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0, 4, 0}

    bus = Bus.tick(bus, 3)
    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0, 1, 0}

    bus = Bus.tick(bus, 1)
    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0xA7, 0, 0x04}
  end

  test "TIMA writes cancel a pending reload while TMA writes affect it" do
    overflowed =
      Bus.new()
      |> Bus.write(0xFF05, 0xFF)
      |> Bus.write(0xFF07, 0x05)
      |> Bus.tick(16)

    cancelled = overflowed |> Bus.write(0xFF05, 0x55) |> Bus.tick(4)
    assert {cancelled.tima, cancelled.timer_reload, cancelled.interrupt_flags} == {0x55, 0, 0}

    reloaded = overflowed |> Bus.write(0xFF06, 0x66) |> Bus.tick(4)
    assert {reloaded.tima, reloaded.interrupt_flags} == {0x66, 0x04}
  end

  test "KEY1 is CGB-only and retains only current and prepared speed bits" do
    dmg = Bus.new() |> Bus.write(0xFF4D, 1)
    assert Bus.read(dmg, 0xFF4D) == 0xFF
    refute Bus.cgb?(dmg)

    cgb = Bus.new(<<>>, model: :cgb) |> Bus.tick(0x1234) |> Bus.write(0xFF4D, 0xFF)
    assert Bus.cgb?(cgb)
    refute Bus.double_speed?(cgb)
    assert Bus.read(cgb, 0xFF4D) == 0x7F

    {:speed_switch, cgb} = Bus.stop(cgb)
    assert Bus.double_speed?(cgb)
    assert cgb.divider == 0
    assert Bus.read(cgb, 0xFF4D) == 0xFE
  end
end
