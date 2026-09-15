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
end
