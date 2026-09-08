defmodule Beamicom.GB.HeaderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GB.Header

  test "parses a checksummed DMG header and its size metadata" do
    rom = rom(title: "DOT MATRIX", type: 0x00, rom_size: 0x00, ram_size: 0x00)

    assert {:ok, header} = Header.parse(rom)
    assert header.title == "DOT MATRIX"
    assert header.cgb_flag == 0x00
    assert header.cgb_mode == :dmg_only
    assert header.cartridge_type == :rom_only
    assert header.mapper == :rom_only
    assert header.features == []
    assert header.rom_size == 32 * 1024
    assert header.rom_banks == 2
    assert header.ram_size == 0
    assert header.ram_banks == 0
    assert header.header_checksum_valid?
    assert header.header_checksum == header.calculated_header_checksum
  end

  test "distinguishes compatible and CGB-only games from the CGB flag bits" do
    compatible = rom(title: "COLOR GAME", cgb_flag: 0x81)
    cgb_only = rom(title: "CGB ONLY", cgb_flag: 0xC1)
    no_cgb_support = rom(cgb_flag: 0x40)

    assert {:ok, %{title: "COLOR GAME", cgb_mode: :cgb_compatible}} = Header.parse(compatible)
    assert {:ok, %{title: "CGB ONLY", cgb_mode: :cgb_only}} = Header.parse(cgb_only)
    assert {:ok, %{cgb_mode: :dmg_only}} = Header.parse(no_cgb_support)
  end

  test "preserves the 15-byte title in a CGB header without a manufacturer code" do
    rom = rom(title: "123456789ABCDEF", cgb_flag: 0x80, old_licensee: 0x01)

    assert {:ok, %{title: "123456789ABCDEF", cgb_mode: :cgb_compatible}} = Header.parse(rom)
  end

  test "uses the 11-byte title field when the newer header layout has a manufacturer code" do
    rom =
      rom(
        title: "COLOR QUEST",
        manufacturer: "ABCD",
        cgb_flag: 0x80,
        old_licensee: 0x33
      )

    assert {:ok, %{title: "COLOR QUEST"}} = Header.parse(rom)
  end

  test "reports mapper and hardware features for future MBC implementations" do
    rom = rom(type: 0x10, rom_size: 0x03, ram_size: 0x03)

    assert {:ok, header} = Header.parse(rom)
    assert header.cartridge_type == :mbc3_timer_ram_battery
    assert header.mapper == :mbc3
    assert header.features == [:timer, :ram, :battery]
    assert header.rom_size == 256 * 1024
    assert header.rom_banks == 16
    assert header.ram_size == 32 * 1024
    assert header.ram_banks == 4
  end

  test "supports the uncommon non-power-of-two ROM size codes" do
    for {code, banks} <- [{0x52, 72}, {0x53, 80}, {0x54, 96}] do
      assert {:ok, header} = Header.parse(rom(rom_size: code))
      assert header.rom_banks == banks
      assert header.rom_size == banks * 16 * 1024
    end
  end

  test "rejects an invalid header checksum and permits explicit inspection" do
    valid = rom(title: "CHECKSUM")
    corrupted = put_byte(valid, 0x134, ?X)
    actual = :binary.at(corrupted, 0x14D)
    {:ok, calculated} = Header.calculate_checksum(corrupted)

    assert {:error, {:invalid_header_checksum, ^calculated, ^actual}} = Header.parse(corrupted)

    assert {:ok, header} = Header.parse(corrupted, validate_checksum: false)
    refute header.header_checksum_valid?
  end

  test "rejects short images and unknown metadata codes" do
    assert {:error, {:rom_too_small, 0x150, 3}} = Header.parse(<<1, 2, 3>>)
    assert {:error, {:unknown_cartridge_type, 0x04}} = Header.parse(rom(type: 0x04))
    assert {:error, {:unknown_rom_size, 0x51}} = Header.parse(rom(rom_size: 0x51))
    assert {:error, {:unknown_ram_size, 0x06}} = Header.parse(rom(ram_size: 0x06))
  end

  defp rom(opts) do
    title = Keyword.get(opts, :title, "TEST")
    cgb_flag = Keyword.get(opts, :cgb_flag, 0x00)
    type = Keyword.get(opts, :type, 0x00)
    rom_size = Keyword.get(opts, :rom_size, 0x00)
    ram_size = Keyword.get(opts, :ram_size, 0x00)
    old_licensee = Keyword.get(opts, :old_licensee, 0x00)
    padded_title = :binary.part(title <> :binary.copy(<<0>>, 16), 0, 16)
    manufacturer = Keyword.get(opts, :manufacturer, binary_part(padded_title, 11, 4))

    :binary.copy(<<0>>, 32 * 1024)
    |> put_bytes(0x134, padded_title)
    |> put_bytes(0x13F, manufacturer)
    |> put_byte(0x143, cgb_flag)
    |> put_byte(0x147, type)
    |> put_byte(0x148, rom_size)
    |> put_byte(0x149, ram_size)
    |> put_byte(0x14B, old_licensee)
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
