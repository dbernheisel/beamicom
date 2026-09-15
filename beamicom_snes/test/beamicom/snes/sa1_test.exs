defmodule Beamicom.SNES.SA1Test do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{Bus, Cartridge, SA1}
  alias Beamicom.SNESTestROM

  test "detects SA-1 header variants and installs cartridge state" do
    for type <- [0x34, 0x35] do
      {:ok, cartridge} = sa1_cartridge(cartridge_type: type)
      assert SA1.cartridge?(cartridge)
      assert %SA1{} = Bus.new(cartridge).coprocessor
    end

    {:ok, ordinary} = :lorom |> SNESTestROM.build(cartridge_type: 0x02) |> Cartridge.load()
    refute SA1.cartridge?(ordinary)
  end

  test "maps and protects the S-CPU I-RAM window in 256-byte blocks" do
    bus = sa1_bus()

    {bus, 8} = Bus.cpu_write(bus, 0x003001, 0x11)
    assert Bus.peek(bus, 0x803001) == 0

    {bus, 8} = Bus.cpu_write(bus, 0x002229, 0x01)
    {bus, 8} = Bus.cpu_write(bus, 0x003001, 0x22)
    {bus, 8} = Bus.cpu_write(bus, 0x003101, 0x33)

    assert Bus.peek(bus, 0x803001) == 0x22
    assert Bus.peek(bus, 0x003101) == 0
  end

  test "maps the selectable BW-RAM page and linear banks" do
    bus = sa1_bus(ram_size_code: 5)
    {bus, 8} = Bus.cpu_write(bus, 0x002226, 0x80)
    {bus, 8} = Bus.cpu_write(bus, 0x002224, 0x01)
    {bus, 8} = Bus.cpu_write(bus, 0x006123, 0x5A)

    assert Bus.peek(bus, 0x402123) == 0x5A
    assert Bus.peek(bus, 0x806123) == 0x5A
  end

  test "Super MMC bank registers remap the four one-megabyte ROM regions" do
    media =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0x34, map_mode: 0x23, size: 0x200000)
      |> SNESTestROM.put_byte(0x000000, 0x11)
      |> SNESTestROM.put_byte(0x100000, 0x22)

    {:ok, cartridge} = Cartridge.load(media)
    bus = Bus.new(cartridge)

    assert Bus.peek(bus, 0xC00000) == 0x11
    {bus, 8} = Bus.cpu_write(bus, 0x002220, 0x81)
    assert Bus.peek(bus, 0xC00000) == 0x22
  end

  test "implements signed multiply, unsigned divide, and 40-bit accumulation" do
    sa1 = sa1_bus().coprocessor

    multiplied =
      sa1
      |> SA1.write_sa1_io(0x2250, 0)
      |> write_math_operands(0xFFFE, 3)

    assert math_bytes(multiplied, 4) == <<0xFA, 0xFF, 0xFF, 0xFF>>

    divided =
      sa1
      |> SA1.write_sa1_io(0x2250, 1)
      |> write_math_operands(10, 3)

    assert math_bytes(divided, 4) == <<3, 0, 1, 0>>

    accumulated =
      sa1
      |> SA1.write_sa1_io(0x2250, 2)
      |> write_math_operands(2, 3)
      |> write_math_operands(4, 5)

    assert math_bytes(accumulated, 5) == <<26, 0, 0, 0, 0>>
  end

  test "SA-1 to S-CPU message IRQ observes enable and clear handshakes" do
    bus = sa1_bus()
    {bus, 8} = Bus.cpu_write(bus, 0x002201, 0x80)
    sa1 = SA1.write_sa1_io(bus.coprocessor, 0x2209, 0x80)
    bus = %{bus | coprocessor: sa1}

    assert Bus.irq_pending?(bus)
    assert Bus.peek(bus, 0x002300) == 0x80

    {bus, 8} = Bus.cpu_write(bus, 0x002202, 0x80)
    refute Bus.irq_pending?(bus)
  end

  defp sa1_cartridge(opts) do
    :lorom
    |> SNESTestROM.build(Keyword.merge([cartridge_type: 0x34, map_mode: 0x23], opts))
    |> Cartridge.load()
  end

  defp sa1_bus(opts \\ []) do
    {:ok, cartridge} = sa1_cartridge(opts)
    Bus.new(cartridge)
  end

  defp write_math_operands(sa1, a, b) do
    sa1
    |> SA1.write_sa1_io(0x2251, a)
    |> SA1.write_sa1_io(0x2252, a >>> 8)
    |> SA1.write_sa1_io(0x2253, b)
    |> SA1.write_sa1_io(0x2254, b >>> 8)
  end

  defp math_bytes(sa1, count) do
    for register <- 0x2306..(0x2306 + count - 1), into: <<>> do
      <<SA1.read_sa1_io(sa1, register)>>
    end
  end
end
