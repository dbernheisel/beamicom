defmodule Beamicom.SNES.SuperFXTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{Bus, CPU, Cartridge, SuperFX}
  alias Beamicom.SNESTestROM

  test "detects SuperFX cartridge header variants" do
    for type <- [0x13, 0x14, 0x15, 0x1A] do
      {:ok, cartridge} = :lorom |> SNESTestROM.build(cartridge_type: type) |> Cartridge.load()
      assert SuperFX.cartridge?(cartridge)
      assert %SuperFX{} = Bus.new(cartridge).coprocessor
    end
  end

  test "maps the GSU register file, cache, and declared expansion RAM geometry" do
    bus = superfx_bus(<<0x00>>, expansion_ram_size_code: 5)

    {bus, 6} = Bus.cpu_write(bus, 0x00300A, 0x34)
    {bus, 6} = Bus.cpu_write(bus, 0x80300B, 0x12)
    assert Bus.peek(bus, 0x00300A) == 0x34
    assert Bus.peek(bus, 0x80300B) == 0x12

    {bus, 6} = Bus.cpu_write(bus, 0x003100, 0xA5)
    assert Bus.peek(bus, 0x803100) == 0xA5

    {bus, 8} = Bus.cpu_write(bus, 0x700042, 0x5A)
    {bus, 8} = Bus.cpu_write(bus, 0x710042, 0xC3)
    assert bus.coprocessor.ram_size == 0x8000
    assert Bus.peek(bus, 0x700042) == 0xC3
    assert Bus.peek(bus, 0x710042) == 0xC3

    assert Bus.peek(bus, 0x006123) == 0xFF
    {bus, 8} = Bus.cpu_write(bus, 0x006123, 0x77)
    assert Bus.peek(bus, 0x806123) == 0x77
    assert Bus.peek(bus, 0x700123) == 0x77

    {bus, 8} = Bus.cpu_write(bus, 0x700123, 0x66)
    assert Bus.peek(bus, 0x006123) == 0x66

    {bus, 6} = Bus.cpu_write(bus, 0x003033, 1)
    assert bus.coprocessor.bramr == 1
    assert Bus.peek(bus, 0x006123) == 0x66

    {bus, 8} = Bus.cpu_write(bus, 0xF00042, 0x99)
    assert Bus.peek(bus, 0x700042) == 0x99
  end

  test "maps the S-CPU linear 64 KiB SuperFX ROM banks without LoROM half mirroring" do
    media =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0x15, size: 0x20_0000)
      |> SNESTestROM.put_byte(0x0100, 0x11)
      |> SNESTestROM.put_byte(0x8100, 0x22)

    {:ok, cartridge} = Cartridge.load(media)
    bus = Bus.new(cartridge)

    assert Bus.peek(bus, 0x400100) == 0x11
    assert Bus.peek(bus, 0x408100) == 0x22
    assert Bus.peek(bus, 0xC00100) == 0x11
    assert Bus.peek(bus, 0xC08100) == 0x22
  end

  test "CPU execution uses the SuperFX linear ROM mapping" do
    media =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0x15, size: 0x20_0000)
      |> SNESTestROM.put_byte(0x0000, 0xAF)
      |> SNESTestROM.put_byte(0x0001, 0x00)
      |> SNESTestROM.put_byte(0x0002, 0x81)
      |> SNESTestROM.put_byte(0x0003, 0x40)
      |> SNESTestROM.put_byte(0x0100, 0x11)
      |> SNESTestROM.put_byte(0x8100, 0x22)

    {:ok, cartridge} = Cartridge.load(media)
    bus = Bus.new(cartridge)
    cpu = CPU.reset(bus)

    assert {:ok, %{a: 0x22}, _bus, _clocks} = CPU.step(cpu, bus)
  end

  test "executes a ROM-resident GSU program through STOP and raises its IRQ" do
    # IWT R1,#$1234; IWT R2,#$0002; FROM R1; ADD R2;
    # IWT R3,#$0040; STW (R3); STOP
    program = <<0xF1, 0x34, 0x12, 0xF2, 0x02, 0x00, 0xB1, 0x52, 0xF3, 0x40, 0x00, 0x33, 0x00>>
    bus = superfx_bus(program)

    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)

    assert Bus.peek(bus, 0x700040) == 0x36
    assert Bus.peek(bus, 0x700041) == 0x12
    refute (Bus.peek(bus, 0x003030) &&& 0x20) != 0
    assert Bus.irq_pending?(bus)
    assert bus.coprocessor.halted_reason == nil
    assert bus.coprocessor.last_job_instructions == 8

    {status_high, bus, 6} = Bus.cpu_read(bus, 0x003031)
    assert (status_high &&& 0x80) != 0
    refute Bus.irq_pending?(bus)
  end

  test "LSR shifts logically while ASR preserves the sign bit" do
    lsr = run_superfx_program(<<0xF1, 0x01, 0x80, 0xB1, 0x03, 0x00>>)
    assert Bus.peek(lsr, 0x003000) == 0x00
    assert Bus.peek(lsr, 0x003001) == 0x40
    assert (Bus.peek(lsr, 0x003030) &&& 0x04) != 0
    refute (Bus.peek(lsr, 0x003030) &&& 0x08) != 0

    asr = run_superfx_program(<<0xF1, 0x01, 0x80, 0xB1, 0x96, 0x00>>)
    assert Bus.peek(asr, 0x003000) == 0x00
    assert Bus.peek(asr, 0x003001) == 0xC0
    assert (Bus.peek(asr, 0x003030) &&& 0x0C) == 0x0C
  end

  test "MERGE writes its unusual nibble summary flags in one result" do
    bus = run_superfx_program(<<0xF7, 0x00, 0xF0, 0xF8, 0x00, 0x0F, 0x70, 0x00>>)

    assert Bus.peek(bus, 0x003000) == 0x0F
    assert Bus.peek(bus, 0x003001) == 0xF0
    assert (Bus.peek(bus, 0x003030) &&& 0x1E) == 0x1E
  end

  test "branch opcodes $06 and $07 use the hardware signed-comparison ordering" do
    branch_program = fn opcode ->
      <<opcode, 0x05, 0x01, 0xF0, 0x11, 0x11, 0x00, 0xF0, 0x22, 0x22, 0x00>>
    end

    signed_greater_or_equal = run_superfx_program(branch_program.(0x06))
    signed_less_than = run_superfx_program(branch_program.(0x07))

    assert Bus.peek(signed_greater_or_equal, 0x003000) == 0x22
    assert Bus.peek(signed_greater_or_equal, 0x003001) == 0x22
    assert Bus.peek(signed_less_than, 0x003000) == 0x11
    assert Bus.peek(signed_less_than, 0x003001) == 0x11
  end

  test "GSU banks $60-$7F read expansion RAM" do
    # IWT R1,#$0060; FROM R1; ALT3; ROMB; IWT R14,#$0042; GETB; STOP
    program = <<0xF1, 0x60, 0x00, 0xB1, 0x3F, 0xDF, 0xFE, 0x42, 0x00, 0xEF, 0x00>>
    bus = superfx_bus(program)
    {bus, 8} = Bus.cpu_write(bus, 0x700042, 0xA5)
    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)

    assert Bus.peek(bus, 0x003000) == 0xA5
  end

  test "LOOP decrements R12 and branches through R13 until zero" do
    program = <<0xFC, 0x02, 0x00, 0xFD, 0x06, 0x90, 0x3C, 0x01, 0x00>>
    bus = run_superfx_program(program)

    assert Bus.peek(bus, 0x003018) == 0
    assert Bus.peek(bus, 0x003019) == 0
    assert (Bus.peek(bus, 0x003030) &&& 0x02) != 0
    assert bus.coprocessor.last_job_instructions == 8
  end

  test "WITH and FROM move a register and preserve FROM flag semantics" do
    bus = run_superfx_program(<<0xF1, 0x80, 0x00, 0x22, 0xB1, 0x00>>)

    assert Bus.peek(bus, 0x003004) == 0x80
    assert Bus.peek(bus, 0x003005) == 0
    assert (Bus.peek(bus, 0x003030) &&& 0x1A) == 0x10
  end

  test "consecutive INC R10 instructions preserve register and instruction accounting" do
    bus = run_superfx_program(<<0xDA, 0xDA, 0x00>>)

    assert Bus.peek(bus, 0x003014) == 2
    assert Bus.peek(bus, 0x003015) == 0
    assert bus.coprocessor.last_job_instructions == 4
  end

  test "increment, indexed load, and subtract sequence preserves GSU state" do
    bus = superfx_bus(<<0xDA, 0xB1, 0x5A, 0x40, 0x6B, 0x00>>)
    {bus, 6} = Bus.cpu_write(bus, 0x003002, 0x40)
    {bus, 6} = Bus.cpu_write(bus, 0x003003, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x003014, 0x01)
    {bus, 6} = Bus.cpu_write(bus, 0x003015, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x003016, 0x02)
    {bus, 6} = Bus.cpu_write(bus, 0x003017, 0x00)
    {bus, 8} = Bus.cpu_write(bus, 0x700042, 0x34)
    {bus, 8} = Bus.cpu_write(bus, 0x700043, 0x12)
    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)

    assert Bus.peek(bus, 0x003000) == 0x32
    assert Bus.peek(bus, 0x003001) == 0x12
    assert Bus.peek(bus, 0x003014) == 2
    assert (Bus.peek(bus, 0x003030) &&& 0x1E) == 0x04
    assert bus.coprocessor.ramaddr == 0x42
    assert bus.coprocessor.last_job_instructions == 7
  end

  test "PLOT addresses screen RAM independently of the LD/ST RAM bank" do
    bus = superfx_bus(<<0x00>>, expansion_ram_size_code: 7)
    {bus, 8} = Bus.cpu_write(bus, 0x700000, 0)
    {bus, 8} = Bus.cpu_write(bus, 0x700001, 0)

    # R0=1; COLOR; ALT2+RAMB selects RAM bank 1; PLOT three character groups
    # so the first group leaves the hardware's two-entry pixel cache.
    {bus, 6} = Bus.cpu_write(bus, 0x003000, 1)
    program = [0x4E, 0x3E, 0xDF, 0x4C, 0xF1, 8, 0, 0x4C, 0xF1, 16, 0, 0x4C, 0x00, 1, 1, 1]

    bus =
      program
      |> Enum.with_index()
      |> Enum.reduce(bus, fn {byte, index}, bus ->
        {bus, 6} = Bus.cpu_write(bus, 0x003100 + index, byte)
        bus
      end)

    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0)

    assert bus.coprocessor.rambr == 1
    assert Bus.peek(bus, 0x700000) == 0x80
    assert Bus.peek(bus, 0x710000) == 0xFF
  end

  test "batches the RAM-fed horizontal PLOT loop without changing pixel or instruction state" do
    program =
      <<0xF1, 0x00, 0x00, 0xF2, 0x00, 0x00, 0xFC, 0x07, 0x00, 0xFD, 0x11, 0x90, 0xF0, 0x01, 0x00,
        0x4E, 0x4C, 0x3D, 0x41, 0x4E, 0x3C, 0x4C, 0xF1, 0x08, 0x00, 0x4C, 0x00>>

    bus = superfx_bus(program)

    bus =
      Enum.reduce(1..7, bus, fn address, bus ->
        {bus, 8} = Bus.cpu_write(bus, 0x700000 + address, address + 1)
        bus
      end)

    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)

    assert Bus.peek(bus, 0x700000) == 0xAA
    assert Bus.peek(bus, 0x700001) == 0x66
    assert bus.coprocessor.batched_plot_spans == 1
    assert bus.coprocessor.batched_plot_pixels == 7
    assert bus.coprocessor.last_job_instructions == 46
  end

  test "batches the masked horizontal PLOT loop without consuming its terminal iteration" do
    program =
      <<0xF1, 0x00, 0x00, 0xF2, 0x00, 0x00, 0xF4, 0xFF, 0x00, 0xFA, 0x00, 0x80, 0xFB, 0x00, 0x80,
        0xFC, 0x04, 0x00, 0xFD, 0x15, 0x90, 0xA0, 0x00, 0x2B, 0x04, 0x04, 0x2A, 0x04, 0x04, 0x4E,
        0x4C, 0x21, 0x74, 0x08, 0x05, 0x01, 0xA0, 0x20, 0x12, 0x52, 0x3C, 0x01, 0xF0, 0x01, 0x00,
        0x4E, 0xF1, 0x08, 0x00, 0x4C, 0xF1, 0x10, 0x00, 0x4C, 0x00>>

    # This byte is skipped by the taken BNE. Changing it preserves scalar
    # behavior while deliberately defeating the kernel's opcode guard.
    <<prefix::binary-size(39), _guarded, suffix::binary>> = program
    scalar_program = prefix <> <<0x53>> <> suffix

    bus = superfx_bus(program)
    scalar_bus = superfx_bus(scalar_program)

    {bus, 8} = Bus.cpu_write(bus, 0x700000, 0)
    {bus, 8} = Bus.cpu_write(bus, 0x700001, 0)
    {scalar_bus, 8} = Bus.cpu_write(scalar_bus, 0x700000, 0)
    {scalar_bus, 8} = Bus.cpu_write(scalar_bus, 0x700001, 0)
    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)
    {scalar_bus, 6} = Bus.cpu_write(scalar_bus, 0x00301E, 0x00)
    {scalar_bus, 6} = Bus.cpu_write(scalar_bus, 0x00301F, 0x90)

    assert bus.coprocessor.batched_plot_spans == 1
    assert bus.coprocessor.batched_plot_pixels == 3
    assert scalar_bus.coprocessor.batched_plot_spans == 0

    assert superfx_registers(bus) == superfx_registers(scalar_bus)
    assert superfx_ram(bus, 64) == superfx_ram(scalar_bus, 64)
    assert comparable_superfx_state(bus) == comparable_superfx_state(scalar_bus)
  end

  defp superfx_bus(program, opts \\ []) do
    media =
      :lorom
      |> SNESTestROM.build(Keyword.merge([cartridge_type: 0x15], opts))
      |> SNESTestROM.put_bytes(0x1000, program)

    {:ok, cartridge} = Cartridge.load(media)
    Bus.new(cartridge)
  end

  defp run_superfx_program(program) do
    bus = superfx_bus(program)
    {bus, 6} = Bus.cpu_write(bus, 0x00301E, 0x00)
    {bus, 6} = Bus.cpu_write(bus, 0x00301F, 0x90)
    bus
  end

  defp superfx_registers(bus) do
    Enum.map(0..15, fn register ->
      low = Bus.peek(bus, 0x003000 + register * 2)
      high = Bus.peek(bus, 0x003001 + register * 2)
      low ||| high <<< 8
    end)
  end

  defp superfx_ram(bus, size), do: Enum.map(0..(size - 1), &Bus.peek(bus, 0x700000 + &1))

  defp comparable_superfx_state(bus) do
    bus.coprocessor
    |> Map.from_struct()
    |> Map.drop([:regs, :ram, :bram, :cache, :batched_plot_spans, :batched_plot_pixels])
  end
end
