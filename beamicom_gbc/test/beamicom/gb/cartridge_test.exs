defmodule Beamicom.GB.CartridgeTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GB.Cartridge
  alias Beamicom.GB.Cartridge.RAM

  test "loads two fixed ROM banks and reads both address windows directly" do
    rom = rom(bank0: 0x21, bank1: 0x84)

    assert {:ok, cartridge} = Cartridge.load(rom)
    assert Cartridge.read(cartridge, 0x0000) == 0x21
    assert Cartridge.read(cartridge, 0x3FFF) == 0x21
    assert Cartridge.read(cartridge, 0x4000) == 0x84
    assert Cartridge.read(cartridge, 0x7FFF) == 0x84
    assert Cartridge.read(cartridge, 0x8000) == 0xFF
  end

  test "initializes, reads, and writes external RAM on no-MBC RAM cartridges" do
    rom = rom(type: 0x08, ram_size: 0x02)
    assert {:ok, cartridge} = Cartridge.load(rom)
    assert RAM.size(cartridge.ram) == 8 * 1024
    assert Cartridge.read(cartridge, 0xA123) == 0

    cartridge = Cartridge.write(cartridge, 0xA123, 0x5A)
    assert Cartridge.read(cartridge, 0xA123) == 0x5A
    assert Cartridge.write(cartridge, 0x8000, 0x99) == cartridge
  end

  test "mirrors the uncommon 2 KiB RAM allocation across its 8 KiB window" do
    cartridge = rom(type: 0x08, ram_size: 0x01) |> Cartridge.load() |> elem(1)
    cartridge = Cartridge.write(cartridge, 0xA001, 0x77)

    assert Cartridge.read(cartridge, 0xA801) == 0x77
  end

  test "keeps persistence as a flat binary while live RAM is paged" do
    source = :binary.copy(<<0x3C>>, 8 * 1024)
    rom = rom(type: 0x09, ram_size: 0x02)

    assert {:ok, cartridge} = Cartridge.load(rom, persistence: %{ram: source})
    assert %RAM{size: 8_192, pages: pages} = cartridge.ram
    assert tuple_size(pages) == 32
    assert Cartridge.persistent_data(cartridge) == %{ram: source}

    changed = Cartridge.write(cartridge, 0xA100, 0xA7)
    assert Cartridge.persistent_data(changed).ram != source

    assert {:ok, restored} = Cartridge.restore_persistent_data(changed, %{ram: source})
    assert Cartridge.read(restored, 0xA100) == 0x3C
    assert Cartridge.persistent_data(restored) == %{ram: source}
  end

  test "rejects mapper hardware that is not implemented yet" do
    assert {:error, {:unsupported_mapper, :mmm01}} = Cartridge.load(rom(type: 0x0B))
  end

  test "rejects mismatched image length and malformed no-MBC declarations" do
    assert {:error, {:rom_size_mismatch, 65_536, 32_768}} =
             Cartridge.load(rom(rom_size: 0x01))

    assert {:error, :missing_ram_size} = Cartridge.load(rom(type: 0x08, ram_size: 0x00))

    assert {:error, {:unexpected_ram_size, 8_192}} =
             Cartridge.load(rom(type: 0x00, ram_size: 0x02))

    assert {:error, {:unsupported_rom_only_ram_size, 32_768}} =
             Cartridge.load(rom(type: 0x08, ram_size: 0x03))
  end

  defp rom(opts) do
    bank0 = Keyword.get(opts, :bank0, 0)
    bank1 = Keyword.get(opts, :bank1, 0)
    type = Keyword.get(opts, :type, 0x00)
    rom_size = Keyword.get(opts, :rom_size, 0x00)
    ram_size = Keyword.get(opts, :ram_size, 0x00)

    (:binary.copy(<<bank0>>, 16 * 1024) <> :binary.copy(<<bank1>>, 16 * 1024))
    |> put_bytes(0x134, "TEST" <> :binary.copy(<<0>>, 12))
    |> put_byte(0x143, 0)
    |> put_byte(0x147, type)
    |> put_byte(0x148, rom_size)
    |> put_byte(0x149, ram_size)
    |> with_checksum()
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix_offset = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
  end
end
