defmodule Beamicom.GBA.BackupTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GBA.{Backup, TestROM}

  test "detects standard backup library signatures" do
    assert {:ok, %{type: :eeprom}} = Backup.new(TestROM.build("EEPROM_V124"))
    assert {:ok, %{type: :sram}} = Backup.new(TestROM.build("SRAM_F_V100"))
    assert {:ok, %{type: :flash512}} = Backup.new(TestROM.build("FLASH_V124"))
    assert {:ok, %{type: :flash512}} = Backup.new(TestROM.build("FLASH512_V130"))
    assert {:ok, %{type: :flash1m}} = Backup.new(TestROM.build("FLASH1M_V103"))
  end

  test "reads and writes battery-backed SRAM" do
    {:ok, backup} = Backup.new(TestROM.build("SRAM_V100"))
    assert Backup.read_byte(backup, 0x1234) == 0xFF
    backup = Backup.write_byte(backup, 0x1234, 0x5A)
    assert Backup.read_byte(backup, 0x1234) == 0x5A
    assert Backup.read_byte(backup, 0x9234) == 0x5A
  end

  test "identifies, programs, and erases 64 KiB Flash" do
    {:ok, backup} = Backup.new(TestROM.build("FLASH_V124"))

    backup = command(backup, 0x90)
    assert Backup.read_byte(backup, 0) == 0x32
    assert Backup.read_byte(backup, 1) == 0x1B
    backup = Backup.write_byte(backup, 0, 0xF0)

    backup = command(backup, 0xA0) |> Backup.write_byte(0x1234, 0x5A)
    assert Backup.read_byte(backup, 0x1234) == 0x5A

    backup =
      backup
      |> command(0x80)
      |> Backup.write_byte(0x5555, 0xAA)
      |> Backup.write_byte(0x2AAA, 0x55)
      |> Backup.write_byte(0x1234, 0x30)

    assert Backup.read_byte(backup, 0x1234) == 0xFF
  end

  test "writes and reads 64-bit serial EEPROM blocks" do
    {:ok, backup} = Backup.new(TestROM.build("EEPROM_V124"))
    data = <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0>>

    write_bits = [1, 0] ++ integer_bits(3, 6) ++ binary_bits(data) ++ [0]

    backup =
      backup
      |> Backup.begin_eeprom_write(length(write_bits))
      |> send_bits(write_bits)

    read_bits = [1, 1] ++ integer_bits(3, 6) ++ [0]

    backup =
      backup
      |> Backup.begin_eeprom_write(length(read_bits))
      |> send_bits(read_bits)

    {response, _backup} =
      Enum.map_reduce(1..68, backup, fn _, backup -> Backup.read_eeprom_bit(backup) end)

    assert Enum.take(response, 4) == [0, 0, 0, 0]
    assert response |> Enum.drop(4) |> bits_binary() == data
  end

  defp command(backup, value) do
    backup
    |> Backup.write_byte(0x5555, 0xAA)
    |> Backup.write_byte(0x2AAA, 0x55)
    |> Backup.write_byte(0x5555, value)
  end

  defp send_bits(backup, bits), do: Enum.reduce(bits, backup, &Backup.write_eeprom_bit(&2, &1))

  defp integer_bits(value, count),
    do: for(bit <- Range.new(count - 1, 0, -1), do: value >>> bit &&& 1)

  defp binary_bits(binary), do: for(<<byte <- binary>>, bit <- 7..0//-1, do: byte >>> bit &&& 1)

  defp bits_binary(bits) do
    bits |> Enum.chunk_every(8) |> Enum.map(&bits_integer/1) |> :binary.list_to_bin()
  end

  defp bits_integer(bits), do: Enum.reduce(bits, 0, fn bit, value -> value <<< 1 ||| bit end)
end
