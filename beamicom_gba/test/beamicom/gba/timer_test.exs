defmodule Beamicom.GBA.TimerTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GBA.{Bus, Cartridge, TestROM}

  test "loads the reload value on enable and reloads after overflow" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFFC)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080)

    assert Bus.peek16(bus, 0x0400_0100) == 0xFFFC

    bus = Bus.idle(bus, 3)
    assert Bus.peek16(bus, 0x0400_0100) == 0xFFFF

    bus = Bus.idle(bus, 1)
    assert Bus.peek16(bus, 0x0400_0100) == 0xFFFC
  end

  test "phases divided clocks from system startup" do
    for {select, divisor} <- [{1, 64}, {2, 256}, {3, 1024}] do
      bus = bus()
      {bus, 1} = Bus.write16(bus, 0x0400_0100, 0x1234)
      {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080 ||| select)

      bus = Bus.idle(bus, divisor - Bus.cycle(bus) - 1)
      assert Bus.peek16(bus, 0x0400_0100) == 0x1234

      bus = Bus.idle(bus, 1)
      assert Bus.peek16(bus, 0x0400_0100) == 0x1235
    end
  end

  test "cascades overflows through later timers and requests their IRQs" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFFF)
    {bus, 1} = Bus.write16(bus, 0x0400_0104, 0xFFFE)
    {bus, 1} = Bus.write16(bus, 0x0400_0106, 0x00C4)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080)

    bus = Bus.idle(bus, 1)
    assert Bus.peek16(bus, 0x0400_0104) == 0xFFFF
    assert (Bus.peek16(bus, 0x0400_0202) &&& 1 <<< 4) == 0

    bus = Bus.idle(bus, 1)
    assert Bus.peek16(bus, 0x0400_0104) == 0xFFFE
    assert (Bus.peek16(bus, 0x0400_0202) &&& 1 <<< 4) != 0
  end

  test "exposes timer IRQs through IE and IME" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFFF)
    {bus, 1} = Bus.write16(bus, 0x0400_0200, 1 <<< 3)
    {bus, 1} = Bus.write16(bus, 0x0400_0208, 1)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x00C0)

    refute Bus.interrupt_pending?(bus)
    bus = Bus.idle(bus, 1)

    assert (Bus.peek16(bus, 0x0400_0202) &&& 1 <<< 3) != 0
    assert Bus.interrupt_pending?(bus)
  end

  test "defers register effects by one cycle and ignores timer zero count-up" do
    bus =
      bus()
      |> Bus.put8(0x0400_0100, 0x34)
      |> Bus.put8(0x0400_0101, 0x12)
      |> Bus.put8(0x0400_0102, 0x84)

    assert Bus.peek16(bus, 0x0400_0100) == 0
    assert Bus.peek16(bus, 0x0400_0102) == 0

    bus = Bus.idle(bus, 1)

    assert Bus.peek16(bus, 0x0400_0100) == 0x1234
    assert Bus.peek16(bus, 0x0400_0102) == 0x0080
  end

  test "materializes the counter on disable and invalidates the old overflow" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFF0)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080)
    bus = Bus.idle(bus, 5)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0)
    counter = Bus.peek16(bus, 0x0400_0100)

    bus = Bus.idle(bus, 100)

    assert Bus.peek16(bus, 0x0400_0100) == counter
    assert Bus.peek16(bus, 0x0400_0202) == 0
  end

  test "uses a new reload write only after the current period overflows" do
    bus = bus()
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0xFFFE)
    {bus, 1} = Bus.write16(bus, 0x0400_0102, 0x0080)
    {bus, 1} = Bus.write16(bus, 0x0400_0100, 0x1234)

    assert Bus.peek16(bus, 0x0400_0100) == 0xFFFF

    bus = Bus.idle(bus, 1)
    assert Bus.peek16(bus, 0x0400_0100) == 0x1234
  end

  defp bus do
    {:ok, cartridge} = TestROM.build() |> Cartridge.load()
    Bus.new(cartridge)
  end
end
