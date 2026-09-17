defmodule Beamicom.SNES.SPC700MMIOTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.SPC700

  test "opcode and operand fetches observe timer MMIO and clear its outputs" do
    spc =
      %{SPC700.new(spc_ram(), 0x00FD) | timer_outputs: {0x08, 0x07, 0x00}}
      |> SPC700.run(1)

    assert spc.a == 0x07
    assert spc.pc == 0x00FF
    assert spc.timer_outputs == {0, 0, 0}
  end

  test "opcode fetches from write-only timer targets read zero" do
    spc =
      SPC700.new(spc_ram([{0x00FA, 0xE8}, {0x00FB, 0xFF}]), 0x00FA)
      |> SPC700.run(1)

    assert spc.a == 0
    assert spc.pc == 0x00FB
    assert spc.cycles == 2
  end

  test "timer divider phase free-runs across a control enable edge" do
    spc =
      %{SPC700.new(spc_ram(), 0) | timer_targets: {1, 0, 0}}
      |> SPC700.write_at_clock(0x00F1, 0x01, 127)

    assert spc.timer_phase == {127, 127, 15}
    assert spc.timer_outputs == {0, 0, 0}

    assert {1, spc} = SPC700.read_at_clock(spc, 0x00FD, 128)
    assert spc.timer_outputs == {0, 0, 0}
  end

  test "timer output wraps to four bits and clears on each read" do
    spc = %{
      SPC700.new(spc_ram(), 0)
      | control: 0x01,
        timer_targets: {1, 0, 0}
    }

    assert {15, spc} = SPC700.read_at_clock(spc, 0x00FD, 15 * 128)
    assert {0, spc} = SPC700.read_at_clock(spc, 0x00FD, 31 * 128)
    assert {1, _spc} = SPC700.read_at_clock(spc, 0x00FD, 32 * 128)
  end

  test "timer target writes happen after a coincident divider tick" do
    spc = %{
      SPC700.new(spc_ram(), 0)
      | control: 0x01,
        timer_targets: {3, 0, 0},
        timer_stages: {2, 0, 0},
        timer_phase: {127, 0, 0}
    }

    spc = SPC700.write_at_clock(spc, 0x00FA, 1, 1)

    assert spc.timer_targets == {1, 0, 0}
    assert spc.timer_stages == {0, 0, 0}
    assert spc.timer_outputs == {1, 0, 0}
  end

  test "TEST timer gates halt and resume stage two without resetting divider phase" do
    spc = %{
      SPC700.new(spc_ram(), 0)
      | control: 0x01,
        timer_targets: {1, 0, 0}
    }

    spc = SPC700.write_at_clock(spc, 0x00F0, 0x0B, 0)
    assert spc.test == 0x0B
    assert {0, spc} = SPC700.read_at_clock(spc, 0x00FD, 128)
    assert spc.timer_phase == {0, 0, 0}

    spc = SPC700.write_at_clock(spc, 0x00F0, 0x0A, 128)
    assert {1, _spc} = SPC700.read_at_clock(spc, 0x00FD, 256)
  end

  test "TEST global timer enable bit gates all three timers" do
    spc = %{
      SPC700.new(spc_ram(), 0)
      | control: 0x07,
        timer_targets: {1, 1, 1}
    }

    spc = SPC700.write_at_clock(spc, 0x00F0, 0x02, 0)

    assert {0, spc} = SPC700.read_at_clock(spc, 0x00FD, 128)
    assert {0, spc} = SPC700.read_at_clock(spc, 0x00FE, 128)
    assert {0, _spc} = SPC700.read_at_clock(spc, 0x00FF, 128)
  end

  test "TEST writes are ignored when the direct-page flag is set" do
    spc = %{SPC700.new(spc_ram(), 0) | psw: 0x20}
    spc = SPC700.write_at_clock(spc, 0x00F0, 0x00, 0)

    assert spc.test == 0x0A
  end

  test "TEST RAM gates block ordinary memory but leave MMIO accessible" do
    spc = SPC700.new(spc_ram([{0x0200, 0x33}]), 0)

    spc = SPC700.write_at_clock(spc, 0x00F0, 0x08, 0)
    spc = SPC700.write_at_clock(spc, 0x0200, 0x44, 1)
    spc = SPC700.write_at_clock(spc, 0x00F8, 0x55, 2)

    assert :array.get(0x0200, spc.ram) == 0x33
    assert {0x55, spc} = SPC700.read_at_clock(spc, 0x00F8, 3)

    spc = SPC700.write_at_clock(spc, 0x00F0, 0x0E, 4)
    spc = SPC700.write_at_clock(spc, 0x0200, 0x66, 5)

    assert {0x5A, spc} = SPC700.read_at_clock(spc, 0x0200, 6)
    assert {0xCD, _spc} = SPC700.read_at_clock(spc, 0xFFC0, 6)
    assert :array.get(0x0200, spc.ram) == 0x33
  end

  test "TEST RAM write gate also applies to stack bus writes" do
    spc =
      %{
        SPC700.new(
          spc_ram([{0, 0x3F}, {1, 0x34}, {2, 0x12}, {0x01EF, 0xAA}, {0x01EE, 0xBB}]),
          0
        )
        | test: 0x08
      }
      |> SPC700.run(1)

    assert spc.pc == 0x1234
    assert spc.sp == 0xED
    assert :array.get(0x01EF, spc.ram) == 0xAA
    assert :array.get(0x01EE, spc.ram) == 0xBB
  end

  test "explicit-clock DSP writes preserve the renderer event contract" do
    spc =
      SPC700.new(spc_ram(), 0)
      |> SPC700.write_at_clock(0x00F2, 0x4C, 40)
      |> SPC700.write_at_clock(0x00F3, 0x01, 42)

    assert spc.dsp_events == [{42, 0x4C, 0x01}]

    ram = spc_ram([{0, 0x8F}, {1, 0x4C}, {2, 0xF2}, {3, 0x8F}, {4, 0x01}, {5, 0xF3}])
    {events, spc} = SPC700.new(ram, 0) |> SPC700.run_with_dsp_events(10)

    assert events == [{10, 0x4C, 0x01}]
    assert spc.dsp_events == []
  end

  test "CONTROL port clearing and CPU I/O remain directional" do
    spc = %{
      SPC700.new(spc_ram(), 0, {1, 2, 3, 4})
      | output_ports: {5, 6, 7, 8}
    }

    spc = SPC700.write_at_clock(spc, 0x00F1, 0x30, 0)

    assert spc.input_ports == {0, 0, 0, 0}
    assert spc.output_ports == {5, 6, 7, 8}

    spc = SPC700.write_at_clock(spc, 0x00F4, 0xAA, 1)

    assert {0, _spc} = SPC700.read_at_clock(spc, 0x00F4, 2)
    assert spc.output_ports == {0xAA, 6, 7, 8}
  end

  test "DSPDATA high addresses are read mirrors but reject writes" do
    spc =
      SPC700.new(spc_ram(), 0)
      |> SPC700.write_at_clock(0x00F2, 0x0C, 0)
      |> SPC700.write_at_clock(0x00F3, 0x44, 1)
      |> SPC700.write_at_clock(0x00F2, 0x8C, 2)
      |> SPC700.write_at_clock(0x00F3, 0x99, 3)

    assert {0x44, _spc} = SPC700.read_at_clock(spc, 0x00F3, 4)
    assert spc.dsp_events == [{1, 0x0C, 0x44}]
  end

  test "access-event runs capture effective RAM, MMIO, DSP, and stack writes in bus order" do
    ram =
      spc_ram([
        {0, 0x8F},
        {1, 0x11},
        {2, 0x20},
        {3, 0x8F},
        {4, 0x0C},
        {5, 0xF2},
        {6, 0x8F},
        {7, 0x44},
        {8, 0xF3},
        {9, 0x3F},
        {10, 0x34},
        {11, 0x12}
      ])

    assert {events, spc} = SPC700.new(ram, 0) |> SPC700.run_with_access_events(23)

    assert events == [
             {5, :ram_write, 0x0020, 0x11},
             {10, :ram_write, 0x00F2, 0x0C},
             {15, :ram_write, 0x00F3, 0x44},
             {15, :dsp_write, 0x0C, 0x44},
             {20, :ram_write, 0x01EF, 0x00},
             {21, :ram_write, 0x01EE, 0x0C}
           ]

    assert spc.pc == 0x1234
    assert spc.access_events == []
    refute spc.capture_access_events?
    assert spc.dsp_events == []
  end

  test "access-event runs omit backing writes rejected by TEST while retaining MMIO effects" do
    ram =
      spc_ram([
        {0, 0x8F},
        {1, 0x08},
        {2, 0xF0},
        {3, 0x8F},
        {4, 0x33},
        {5, 0x20},
        {6, 0x8F},
        {7, 0x44},
        {8, 0xF8}
      ])

    assert {events, spc} = SPC700.new(ram, 0) |> SPC700.run_with_access_events(15)

    assert events == [{5, :ram_write, 0x00F0, 0x08}]
    assert spc.aux == {0x44, 0}
    assert :array.get(0x0020, spc.ram) == 0
    assert :array.get(0x00F8, spc.ram) == 0
  end

  test "access-event runs retain accepted writes whose value is unchanged" do
    ram = spc_ram([{0, 0x8F}, {1, 0x00}, {2, 0x20}])

    assert {[{5, :ram_write, 0x0020, 0x00}], _spc} =
             SPC700.new(ram, 0) |> SPC700.run_with_access_events(5)
  end

  test "timeline synchronization receives the pending write value" do
    ram = spc_ram([{0, 0x8F}, {1, 0x22}, {2, 0x20}])
    owner = self()

    sync = fn spc, clock, operation, address, value, state ->
      send(owner, {:access, clock, operation, address, value})
      {:sync, spc, state}
    end

    {_events, _spc, _state} =
      SPC700.run_with_access_events(SPC700.new(ram, 0), 5, :state, sync)

    assert_received {:access, 5, :write, 0x0020, 0x22}
  end

  test "ordinary and legacy runs never accumulate or replay access events" do
    ram = spc_ram([{0, 0x8F}, {1, 0x22}, {2, 0x20}, {3, 0x00}])
    stale_event = {999, :ram_write, 0xFFFF, 0xFF}
    initial = %{SPC700.new(ram, 0) | access_events: [stale_event], capture_access_events?: true}

    ordinary = SPC700.run(initial, 5)
    assert ordinary.access_events == []
    refute ordinary.capture_access_events?

    assert {[], legacy} = SPC700.run_with_dsp_events(initial, 5)
    assert legacy.access_events == []
    refute legacy.capture_access_events?

    assert {[{5, :ram_write, 0x0020, 0x22}], spc} =
             SPC700.run_with_access_events(initial, 5)

    assert {[], spc} = SPC700.run_with_access_events(spc, 2)
    assert spc.access_events == []
    refute spc.capture_access_events?
  end

  test "access clocks remain absolute across separate SPC runs" do
    ram =
      spc_ram([
        {0, 0x8F},
        {1, 0x11},
        {2, 0x20},
        {3, 0x8F},
        {4, 0x22},
        {5, 0x21}
      ])

    assert {[{5, :ram_write, 0x0020, 0x11}], spc} =
             SPC700.new(ram, 0) |> SPC700.run_with_access_events(5)

    assert {[{10, :ram_write, 0x0021, 0x22}], spc} =
             SPC700.run_with_access_events(spc, 5)

    assert spc.cycles == 10
    assert spc.bus_counter == nil
  end

  defp spc_ram(values \\ []) do
    Enum.reduce(values, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end
end
