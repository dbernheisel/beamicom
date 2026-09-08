defmodule Beamicom.GB.CPUTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.{Bus, CPU}

  @invalid [0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD]

  # M-cycle table with all flags clear: NZ/NC conditions are taken and Z/C
  # conditions are not. CB uses opcode $00 here and therefore takes 2 M-cycles.
  @base_mcycles {
    {1, 3, 2, 2, 1, 1, 2, 1, 5, 2, 2, 2, 1, 1, 2, 1},
    {1, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1},
    {3, 3, 2, 2, 1, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 1},
    {3, 3, 2, 2, 3, 3, 3, 1, 2, 2, 2, 2, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {2, 2, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1},
    {5, 3, 4, 4, 6, 4, 2, 4, 2, 4, 3, 2, 3, 6, 2, 4},
    {5, 3, 4, 1, 6, 4, 2, 4, 2, 4, 3, 1, 3, 1, 2, 4},
    {3, 3, 2, 1, 1, 4, 2, 4, 4, 1, 4, 1, 1, 1, 2, 4},
    {3, 3, 2, 1, 1, 4, 2, 4, 3, 2, 4, 1, 1, 1, 2, 4}
  }

  defp run(program, opts \\ [], memory \\ []) do
    bus =
      Enum.reduce(memory, Bus.new(program), fn {address, value}, bus ->
        Bus.write(bus, address, value)
      end)

    CPU.step(CPU.new(opts), bus)
  end

  describe "decoder coverage" do
    test "all 256 base encodings report their exact M-cycle timing" do
      for opcode <- 0x00..0xFF do
        {_cpu, _bus, cycles} = run(<<opcode, 0, 0>>, h: 0x20, sp: 0xFFF0)
        expected = @base_mcycles |> elem(opcode >>> 4) |> elem(opcode &&& 0x0F)

        assert cycles == expected,
               "opcode #{Integer.to_string(opcode, 16)} took #{cycles}, expected #{expected}"
      end
    end

    test "every documented base opcode executes without locking" do
      for opcode <- 0x00..0xFF, opcode not in @invalid do
        {cpu, _bus, cycles} = run(<<opcode, 0, 0>>, h: 0x20, sp: 0xFFF0)
        assert cpu.run_state != :locked, "opcode #{Integer.to_string(opcode, 16)} locked"
        assert cycles in 1..6
      end
    end

    test "all 256 CB-prefixed opcodes execute with their register/memory timings" do
      for opcode <- 0x00..0xFF do
        z = opcode &&& 0x07
        group = opcode >>> 6
        expected = if z != 6, do: 2, else: if(group == 1, do: 3, else: 4)

        {cpu, _bus, cycles} = run(<<0xCB, opcode>>, [h: 0x80], [{0x8000, 0xA5}])
        assert cpu.run_state != :locked
        assert cycles == expected
        assert cpu.pc == 2
      end
    end

    test "the eleven invalid opcodes enter a persistent locked state" do
      for opcode <- @invalid do
        {cpu, bus, 1} = run(<<opcode, 0x3E, 0x99>>)
        assert cpu.run_state == :locked
        assert cpu.pc == 1

        {same, _bus, 1} = CPU.step(cpu, bus)
        assert same == cpu
      end
    end
  end

  describe "loads and register pairs" do
    test "8-bit immediate, register, and indirect loads use correct cycles" do
      {cpu, _bus, 2} = run(<<0x06, 0xA5>>)
      assert cpu.b == 0xA5
      assert cpu.pc == 2

      {cpu, _bus, 1} = run(<<0x41>>, c: 0x5A)
      assert cpu.b == 0x5A

      {cpu, _bus, 2} = run(<<0x46>>, [h: 0xC0, l: 0x01], [{0xC001, 0x77}])
      assert cpu.b == 0x77

      {_cpu, bus, 2} = run(<<0x70>>, b: 0x88, h: 0xC0, l: 0x01)
      assert Bus.read(bus, 0xC001) == 0x88

      {_cpu, bus, 3} = run(<<0x36, 0xCC>>, h: 0xC0, l: 0x01)
      assert Bus.read(bus, 0xC001) == 0xCC
    end

    test "16-bit immediates and stack pointer store are little endian" do
      {cpu, _bus, 3} = run(<<0x01, 0x34, 0x12>>)
      assert {cpu.b, cpu.c, cpu.pc} == {0x12, 0x34, 3}

      {_cpu, bus, 5} = run(<<0x08, 0x00, 0xC0>>, sp: 0xBEEF)
      assert Bus.read(bus, 0xC000) == 0xEF
      assert Bus.read(bus, 0xC001) == 0xBE
    end

    test "BC/DE indirect and HL auto increment/decrement modes" do
      {_cpu, bus, 2} = run(<<0x02>>, a: 0x12, b: 0xC0, c: 0x10)
      assert Bus.read(bus, 0xC010) == 0x12

      {cpu, _bus, 2} = run(<<0x1A>>, [d: 0xC0, e: 0x10], [{0xC010, 0x34}])
      assert cpu.a == 0x34

      {cpu, bus, 2} = run(<<0x22>>, a: 0x56, h: 0xC0, l: 0xFF)
      assert Bus.read(bus, 0xC0FF) == 0x56
      assert {cpu.h, cpu.l} == {0xC1, 0x00}

      {cpu, _bus, 2} = run(<<0x3A>>, [h: 0xC1, l: 0], [{0xC100, 0x78}])
      assert cpu.a == 0x78
      assert {cpu.h, cpu.l} == {0xC0, 0xFF}
    end

    test "high-memory and absolute loads address the expected locations" do
      {_cpu, bus, 3} = run(<<0xE0, 0x42>>, a: 0xAB)
      assert Bus.read(bus, 0xFF42) == 0xAB

      {cpu, _bus, 2} = run(<<0xF2>>, [c: 0x80], [{0xFF80, 0xCD}])
      assert cpu.a == 0xCD

      {_cpu, bus, 4} = run(<<0xEA, 0x34, 0xC2>>, a: 0xEF)
      assert Bus.read(bus, 0xC234) == 0xEF

      {cpu, _bus, 4} = run(<<0xFA, 0x34, 0xC2>>, [], [{0xC234, 0x19}])
      assert cpu.a == 0x19
    end
  end

  describe "8-bit arithmetic and flags" do
    test "ADD and ADC set zero, half-carry, and carry" do
      {cpu, _bus, 1} = run(<<0x80>>, a: 0x0F, b: 0x01)
      assert cpu.a == 0x10
      refute CPU.flag?(cpu, :z)
      refute CPU.flag?(cpu, :n)
      assert CPU.flag?(cpu, :h)
      refute CPU.flag?(cpu, :c)

      {cpu, _bus, 1} = run(<<0x89>>, a: 0xFF, c: 0, f: 0x10)
      assert cpu.a == 0
      assert cpu.f == 0xB0
    end

    test "SUB, SBC, and CP calculate borrows while CP preserves A" do
      {cpu, _bus, 2} = run(<<0xD6, 0x01>>, a: 0x10)
      assert cpu.a == 0x0F
      assert cpu.f == 0x60

      {cpu, _bus, 1} = run(<<0x9A>>, a: 0, d: 0, f: 0x10)
      assert cpu.a == 0xFF
      assert cpu.f == 0x70

      {cpu, _bus, 2} = run(<<0xFE, 0x42>>, a: 0x42)
      assert cpu.a == 0x42
      assert cpu.f == 0xC0
    end

    test "AND, XOR, and OR produce their specified flags" do
      {cpu, _bus, 1} = run(<<0xA0>>, a: 0xF0, b: 0x0F)
      assert {cpu.a, cpu.f} == {0, 0xA0}

      {cpu, _bus, 2} = run(<<0xEE, 0xFF>>, a: 0x0F)
      assert {cpu.a, cpu.f} == {0xF0, 0}

      {cpu, _bus, 1} = run(<<0xB1>>, a: 0, c: 0)
      assert {cpu.a, cpu.f} == {0, 0x80}
    end

    test "INC and DEC preserve carry and use nibble overflow/borrow" do
      {cpu, _bus, 1} = run(<<0x04>>, b: 0x0F, f: 0x10)
      assert {cpu.b, cpu.f} == {0x10, 0x30}

      {cpu, _bus, 1} = run(<<0x05>>, b: 0x00, f: 0x10)
      assert {cpu.b, cpu.f} == {0xFF, 0x70}

      {cpu, bus, 3} = run(<<0x34>>, [h: 0xC0, f: 0x10], [{0xC000, 0xFF}])
      assert Bus.read(bus, 0xC000) == 0
      assert cpu.f == 0xB0
    end

    test "DAA handles addition and subtraction BCD corrections" do
      {cpu, _bus, 1} = run(<<0x27>>, a: 0x3C, f: 0x20)
      assert {cpu.a, cpu.f} == {0x42, 0}

      {cpu, _bus, 1} = run(<<0x27>>, a: 0x9A)
      assert {cpu.a, cpu.f} == {0, 0x90}

      {cpu, _bus, 1} = run(<<0x27>>, a: 0x1B, f: 0x60)
      assert {cpu.a, cpu.f} == {0x15, 0x40}
    end

    test "accumulator rotates differ from CB rotates by always clearing zero" do
      {cpu, _bus, 1} = run(<<0x07>>, a: 0x80, f: 0x80)
      assert {cpu.a, cpu.f} == {1, 0x10}

      {cpu, _bus, 2} = run(<<0xCB, 0x07>>, a: 0)
      assert {cpu.a, cpu.f} == {0, 0x80}
    end
  end

  describe "16-bit arithmetic" do
    test "ADD HL preserves Z and sets half-carry/carry from bits 11/15" do
      {cpu, _bus, 2} = run(<<0x09>>, b: 0x00, c: 0x01, h: 0x0F, l: 0xFF, f: 0x80)
      assert {cpu.h, cpu.l, cpu.f} == {0x10, 0x00, 0xA0}

      {cpu, _bus, 2} = run(<<0x19>>, d: 0x00, e: 0x01, h: 0xFF, l: 0xFF)
      assert {cpu.h, cpu.l, cpu.f} == {0, 0, 0x30}
    end

    test "signed SP operations wrap and derive flags from the unsigned low byte" do
      {cpu, _bus, 4} = run(<<0xE8, 0xFF>>, sp: 0x0001, f: 0xF0)
      assert {cpu.sp, cpu.f} == {0, 0x30}

      {cpu, _bus, 3} = run(<<0xF8, 0x08>>, sp: 0xFFF8)
      assert {cpu.h, cpu.l, cpu.sp, cpu.f} == {0, 0, 0xFFF8, 0x30}

      {cpu, _bus, 2} = run(<<0xF9>>, h: 0xBE, l: 0xEF)
      assert cpu.sp == 0xBEEF
    end
  end

  describe "flow control and stack" do
    test "relative jumps sign-extend, wrap, and use taken/not-taken timings" do
      {cpu, _bus, 3} = run(<<>>, [pc: 0xFFFE], [{0xFFFE, 0x18}, {0xFFFF, 0xFC}])
      assert cpu.pc == 0xFFFC

      {cpu, _bus, 2} = run(<<0x20, 0x7F>>, f: 0x80)
      assert cpu.pc == 2

      {cpu, _bus, 3} = run(<<0x20, 0x7F>>)
      assert cpu.pc == 0x81
    end

    test "conditional and unconditional JP use correct timings" do
      {cpu, _bus, 3} = run(<<0xCA, 0x34, 0x12>>)
      assert cpu.pc == 3

      {cpu, _bus, 4} = run(<<0xCA, 0x34, 0x12>>, f: 0x80)
      assert cpu.pc == 0x1234

      {cpu, _bus, 1} = run(<<0xE9>>, h: 0xAB, l: 0xCD)
      assert cpu.pc == 0xABCD
    end

    test "PUSH/POP store high then low and AF masks its unused flag nibble" do
      {cpu, bus, 4} = run(<<0xC5>>, b: 0x12, c: 0x34, sp: 0xD000)
      assert cpu.sp == 0xCFFE
      assert Bus.read(bus, 0xCFFE) == 0x34
      assert Bus.read(bus, 0xCFFF) == 0x12

      {cpu, _bus, 3} = run(<<0xF1>>, [sp: 0xCFFE], [{0xCFFE, 0xFF}, {0xCFFF, 0xAB}])
      assert {cpu.a, cpu.f, cpu.sp} == {0xAB, 0xF0, 0xD000}
    end

    test "CALL, RET, conditional RET, RETI, and RST use stack order and timings" do
      {called, bus, 6} = run(<<0xCD, 0x34, 0x12>>, sp: 0xD000)
      assert {called.pc, called.sp} == {0x1234, 0xCFFE}
      assert Bus.read16(bus, 0xCFFE) == 3

      bus = Bus.write(bus, 0x1234, 0xC9)
      {returned, _bus, 4} = CPU.step(called, bus)
      assert {returned.pc, returned.sp} == {3, 0xD000}

      {cpu, _bus, 2} = run(<<0xC0>>, f: 0x80, sp: 0xC000)
      assert {cpu.pc, cpu.sp} == {1, 0xC000}

      {cpu, _bus, 4} = run(<<0xD9>>, [sp: 0xC000], [{0xC000, 0x78}, {0xC001, 0x56}])
      assert {cpu.pc, cpu.ime_state} == {0x5678, :enabled}

      {cpu, bus, 4} = run(<<0xFF>>, sp: 0xD000)
      assert cpu.pc == 0x38
      assert Bus.read16(bus, 0xCFFE) == 1
    end
  end

  describe "CB bit operations" do
    test "rotate/shift/swap operations update values and flags" do
      {cpu, _bus, 2} = run(<<0xCB, 0x10>>, b: 0x80, f: 0x10)
      assert {cpu.b, cpu.f} == {1, 0x10}

      {cpu, _bus, 2} = run(<<0xCB, 0x2A>>, d: 0x81)
      assert {cpu.d, cpu.f} == {0xC0, 0x10}

      {cpu, _bus, 2} = run(<<0xCB, 0x33>>, e: 0xF0)
      assert {cpu.e, cpu.f} == {0x0F, 0}

      {cpu, bus, 4} = run(<<0xCB, 0x3E>>, [h: 0xC0], [{0xC000, 1}])
      assert Bus.read(bus, 0xC000) == 0
      assert cpu.f == 0x90
    end

    test "BIT preserves carry and RES/SET preserve every flag" do
      {cpu, _bus, 2} = run(<<0xCB, 0x7F>>, a: 0x80, f: 0x10)
      assert cpu.f == 0x30

      {cpu, _bus, 3} = run(<<0xCB, 0x46>>, [h: 0xC0, f: 0x10], [{0xC000, 0}])
      assert cpu.f == 0xB0

      {cpu, _bus, 2} = run(<<0xCB, 0x80>>, b: 0xFF, f: 0xF0)
      assert {cpu.b, cpu.f} == {0xFE, 0xF0}

      {cpu, bus, 4} = run(<<0xCB, 0xFE>>, [h: 0xC0, f: 0xA0], [{0xC000, 0}])
      assert Bus.read(bus, 0xC000) == 0x80
      assert cpu.f == 0xA0
    end
  end

  describe "CPU control state" do
    test "machine state stays compact and keeps the concrete bus separate" do
      fields = CPU.new() |> Map.from_struct() |> Map.keys()

      refute :bus in fields
      assert :ime_state in fields
      assert Enum.count(fields, &(&1 in [:run_state, :halted, :stopped, :locked])) == 1
      assert :run_state in fields
    end

    test "CPU bus cycles expose timer edges before the following read or write" do
      read_bus =
        Bus.new(<<0xF0, 0x05>>)
        |> Bus.tick(8)
        |> Bus.write(0xFF07, 0x05)

      {cpu, read_bus, 3} = CPU.step(CPU.new(), read_bus)
      assert {cpu.a, read_bus.tima, read_bus.divider} == {1, 1, 20}

      write_bus =
        Bus.new(<<0xE0, 0x05>>)
        |> Bus.tick(8)
        |> Bus.write(0xFF07, 0x05)

      {_cpu, write_bus, 3} = CPU.step(CPU.new(a: 0x44), write_bus)
      assert {write_bus.tima, write_bus.divider} == {0x44, 20}
    end

    test "HALT and STOP expose scheduler-visible states without advancing" do
      {halted, bus, 1} = run(<<0x76, 0x00>>)
      assert halted.run_state == :halted
      {same, _bus, 1} = CPU.step(halted, bus)
      assert same == halted

      {stopped, bus, 1} = run(<<0x10, 0x00, 0x00>>)
      assert stopped.run_state == :stopped
      assert stopped.pc == 2
      {same, _bus, 1} = CPU.step(stopped, bus)
      assert same == stopped
    end

    test "EI becomes visible after the following instruction and DI cancels it" do
      {cpu, bus, 1} = run(<<0xFB, 0x00>>)
      assert cpu.ime_state == :scheduled

      {cpu, _bus, 1} = CPU.step(cpu, bus)
      assert cpu.ime_state == :enabled

      {cpu, _bus, 1} = run(<<0xF3>>, ime_state: :enabled)
      assert cpu.ime_state == :disabled
    end

    test "CPL, SCF, and CCF preserve only the specified flags" do
      {cpu, _bus, 1} = run(<<0x2F>>, a: 0x55, f: 0x90)
      assert {cpu.a, cpu.f} == {0xAA, 0xF0}

      {cpu, _bus, 1} = run(<<0x37>>, f: 0xE0)
      assert cpu.f == 0x90

      {cpu, _bus, 1} = run(<<0x3F>>, f: 0x90)
      assert cpu.f == 0x80
    end

    test "interrupts dispatch by priority, clear only their IF bit, and consume five M-cycles" do
      for {interrupt, vector} <- [
            {:vblank, 0x40},
            {:lcd_stat, 0x48},
            {:timer, 0x50},
            {:serial, 0x58},
            {:joypad, 0x60}
          ] do
        bus =
          Bus.new()
          |> Bus.write(0xFFFF, 0x1F)
          |> Bus.write(0xFF0F, 0)
          |> Bus.request_interrupt(interrupt)

        cpu = CPU.new(ime_state: :enabled, pc: 0x2345, sp: 0xD000)
        {cpu, bus, 5} = CPU.step(cpu, bus)

        assert {cpu.pc, cpu.sp, cpu.ime_state} == {vector, 0xCFFE, :disabled}
        assert Bus.read16(bus, 0xCFFE) == 0x2345
        assert bus.interrupt_flags == 0
        assert bus.divider == 20
      end

      bus = Bus.new() |> Bus.write(0xFFFF, 0x1F) |> Bus.write(0xFF0F, 0x1E)
      {cpu, _bus, 5} = CPU.step(CPU.new(ime_state: :enabled), bus)
      assert cpu.pc == 0x48
    end

    test "disabled IME leaves requests pending and EI enables after exactly one instruction" do
      bus =
        Bus.new(<<0xFB, 0x00, 0x00>>)
        |> Bus.write(0xFFFF, 1)
        |> Bus.write(0xFF0F, 1)

      {cpu, bus, 1} = CPU.step(CPU.new(sp: 0xD000), bus)
      assert {cpu.pc, cpu.ime_state} == {1, :scheduled}
      assert bus.interrupt_flags == 1

      {cpu, bus, 1} = CPU.step(cpu, bus)
      assert {cpu.pc, cpu.ime_state} == {2, :enabled}

      {cpu, bus, 5} = CPU.step(cpu, bus)
      assert {cpu.pc, cpu.ime_state} == {0x40, :disabled}
      assert bus.interrupt_flags == 0
    end

    test "a second EI does not postpone an already scheduled enable" do
      bus = Bus.new(<<0xFB, 0xFB, 0x00>>)
      {cpu, bus, 1} = CPU.step(CPU.new(), bus)
      {cpu, _bus, 1} = CPU.step(cpu, bus)
      assert {cpu.pc, cpu.ime_state} == {2, :enabled}
    end

    test "HALT bug suppresses exactly one opcode-fetch PC increment" do
      bus =
        Bus.new(<<0x76, 0x3E, 0x12>>)
        |> Bus.write(0xFFFF, 1)
        |> Bus.write(0xFF0F, 1)

      {cpu, bus, 1} = CPU.step(CPU.new(), bus)
      assert {cpu.pc, cpu.run_state, cpu.halt_bug} == {1, :running, true}

      {cpu, _bus, 2} = CPU.step(cpu, bus)
      assert {cpu.pc, cpu.a, cpu.halt_bug} == {2, 0x3E, false}
    end

    test "HALT bug repeats a CB prefix as the CB opcode" do
      bus =
        Bus.new(<<0x76, 0xCB, 0x11>>)
        |> Bus.write(0xFFFF, 1)
        |> Bus.write(0xFF0F, 1)

      {cpu, bus, 1} = CPU.step(CPU.new(e: 0x80), bus)
      {cpu, _bus, 2} = CPU.step(cpu, bus)

      assert {cpu.pc, cpu.e, cpu.f, cpu.halt_bug} == {2, 0x82, 0, false}
    end

    test "HALT idles hardware, wakes without service when IME is clear, and services when set" do
      {halted, bus, 1} = run(<<0x76, 0x00>>)
      {same, bus, 1} = CPU.step(halted, bus)
      assert same.run_state == :halted
      assert bus.divider == 8

      pending = bus |> Bus.write(0xFFFF, 1) |> Bus.write(0xFF0F, 1)
      {awake, _bus, 1} = CPU.step(halted, pending)
      assert {awake.run_state, awake.pc} == {:running, 2}

      {halted, bus, 1} = run(<<0x76>>, ime_state: :enabled, sp: 0xD000)
      pending = bus |> Bus.write(0xFFFF, 1) |> Bus.write(0xFF0F, 1)
      {servicing, _bus, 5} = CPU.step(halted, pending)

      assert {servicing.run_state, servicing.pc, servicing.ime_state} == {
               :running,
               0x40,
               :disabled
             }
    end

    test "STOP consumes padding, joypad edges wake it, and prepared CGB STOP switches speed" do
      {stopped, bus, 1} = run(<<0x10, 0x00, 0x00>>)
      assert {stopped.run_state, stopped.pc} == {:stopped, 2}

      bus = Bus.signal_joypad_edge(bus)
      {awake, bus, 1} = CPU.step(stopped, bus)
      assert {awake.run_state, awake.pc} == {:running, 3}
      assert bus.interrupt_flags == 0x10

      cgb =
        Bus.new(<<0x10, 0x00, 0x10, 0x00>>, model: :cgb)
        |> Bus.write(0xFF4D, 1)

      {cpu, cgb, 1} = CPU.step(CPU.new(), cgb)
      assert cpu.run_state == :running
      assert cpu.pc == 2
      assert Bus.double_speed?(cgb)
      assert Bus.read(cgb, 0xFF4D) == 0xFE

      cgb = Bus.write(cgb, 0xFF4D, 1)
      {cpu, cgb, 1} = CPU.step(cpu, cgb)
      refute Bus.double_speed?(cgb)
      assert cpu.pc == 4
    end
  end
end
