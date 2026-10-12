defmodule Beamicom.GBA.Cartridge do
  @moduledoc """
  Validates a Game Boy Advance cartridge header and owns its ROM and backup
  device state.
  """

  import Bitwise

  alias Beamicom.GBA.Backup

  @header_size 0xC0
  @maximum_rom_size 0x0200_0000

  @enforce_keys [
    :rom,
    :title,
    :game_code,
    :maker_code,
    :unit_code,
    :device_type,
    :software_version,
    :header_checksum,
    :backup
  ]
  defstruct @enforce_keys

  @doc "Loads and validates cartridge media."
  def load(rom, opts \\ [])

  def load(rom, opts) when is_binary(rom) and is_list(opts) do
    with :ok <- validate_size(rom),
         :ok <- validate_fixed_value(rom),
         :ok <- validate_checksum(rom, opts),
         {:ok, backup} <- Backup.new(rom, opts) do
      {:ok,
       %__MODULE__{
         rom: rom,
         title: text_field(rom, 0xA0, 12),
         game_code: text_field(rom, 0xAC, 4),
         maker_code: text_field(rom, 0xB0, 2),
         unit_code: :binary.at(rom, 0xB3),
         device_type: :binary.at(rom, 0xB4),
         software_version: :binary.at(rom, 0xBC),
         header_checksum: :binary.at(rom, 0xBD),
         backup: backup
       }}
    end
  end

  def load(_rom, _opts), do: {:error, :invalid_media}

  @doc "Reads a byte from one of the mirrored 32 MiB Game Pak ROM windows."
  def read(%__MODULE__{rom: rom}, address) when address in 0x0800_0000..0x0DFF_FFFF do
    read_rom(rom, address)
  end

  @doc "Reads an aligned little-endian halfword from Game Pak ROM."
  def read16(%__MODULE__{rom: rom}, address) when address in 0x0800_0000..0x0DFF_FFFF do
    offset = rom_offset(address)

    if offset + 2 <= byte_size(rom) do
      <<_::binary-size(^offset), value::little-16, _::binary>> = rom
      value
    else
      read_rom(rom, address) ||| read_rom(rom, address + 1) <<< 8
    end
  end

  @doc "Reads an aligned little-endian word from Game Pak ROM."
  def read32(%__MODULE__{rom: rom}, address) when address in 0x0800_0000..0x0DFF_FFFF do
    offset = rom_offset(address)

    if offset + 4 <= byte_size(rom) do
      <<_::binary-size(^offset), value::little-32, _::binary>> = rom
      value
    else
      read_rom(rom, address) ||| read_rom(rom, address + 1) <<< 8 |||
        read_rom(rom, address + 2) <<< 16 ||| read_rom(rom, address + 3) <<< 24
    end
  end

  @doc "Returns the detected backup device type."
  def backup_type(%__MODULE__{backup: backup}), do: backup.type

  @doc "Returns the complete packed backup memory."
  def backup_data(%__MODULE__{backup: backup}), do: Backup.to_binary(backup)

  @doc "Reads an SRAM or Flash byte from the 64 KiB backup window."
  def read_backup(%__MODULE__{backup: backup}, address), do: Backup.read_byte(backup, address)

  @doc "Writes an SRAM byte or Flash command to the backup window."
  def write_backup(%__MODULE__{backup: backup} = cartridge, address, value),
    do: %{cartridge | backup: Backup.write_byte(backup, address, value)}

  @doc "Returns whether an address selects this cartridge's serial EEPROM."
  def eeprom_address?(%__MODULE__{backup: %{type: :eeprom}, rom: rom}, address)
      when address in 0x0D00_0000..0x0DFF_FFFF do
    byte_size(rom) <= 0x0100_0000 or address >= 0x0DFF_FF00
  end

  def eeprom_address?(%__MODULE__{}, _address), do: false

  @doc false
  def begin_eeprom_write(%__MODULE__{backup: backup} = cartridge, count),
    do: %{cartridge | backup: Backup.begin_eeprom_write(backup, count)}

  @doc false
  def write_eeprom_bit(%__MODULE__{backup: backup} = cartridge, value),
    do: %{cartridge | backup: Backup.write_eeprom_bit(backup, value)}

  @doc false
  def read_eeprom_bit(%__MODULE__{backup: backup} = cartridge) do
    {value, backup} = Backup.read_eeprom_bit(backup)
    {value, %{cartridge | backup: backup}}
  end

  defp validate_size(rom) when byte_size(rom) < @header_size,
    do: {:error, {:rom_too_small, @header_size, byte_size(rom)}}

  defp validate_size(rom) when byte_size(rom) > @maximum_rom_size,
    do: {:error, {:rom_too_large, @maximum_rom_size, byte_size(rom)}}

  defp validate_size(_rom), do: :ok

  defp validate_fixed_value(rom) do
    case :binary.at(rom, 0xB2) do
      0x96 -> :ok
      value -> {:error, {:invalid_fixed_value, value}}
    end
  end

  defp validate_checksum(rom, opts) do
    checksum = :binary.at(rom, 0xBD)
    expected = header_checksum(rom)

    if checksum == expected or Keyword.get(opts, :validate_header_checksum, true) == false do
      :ok
    else
      {:error, {:header_checksum_mismatch, expected, checksum}}
    end
  end

  defp header_checksum(rom) do
    rom
    |> binary_part(0xA0, 0x1D)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, sum -> sum + byte end)
    |> then(&(-(&1 + 0x19) &&& 0xFF))
  end

  defp text_field(rom, offset, length) do
    field = binary_part(rom, offset, length)

    case :binary.split(field, <<0>>) do
      [value, _rest] -> value
      [value] -> value
    end
  end

  defp rom_offset(address), do: rem(address - 0x0800_0000, @maximum_rom_size)

  defp read_rom(rom, address) do
    offset = rom_offset(address)
    if offset < byte_size(rom), do: :binary.at(rom, offset), else: 0xFF
  end
end
