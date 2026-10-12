defmodule Beamicom.GBA.Backup do
  @moduledoc "Game Pak SRAM, Flash, and serial EEPROM state."

  import Bitwise

  alias Beamicom.GBA.Memory.Region

  @sram_size 32 * 1024
  @flash512_size 64 * 1024
  @flash1m_size 128 * 1024
  @eeprom_size 8 * 1024

  @enforce_keys [:type, :data]
  defstruct @enforce_keys ++
              [
                flash_state: :ready,
                flash_bank: 0,
                flash_id?: false,
                eeprom_address_bits: 14,
                eeprom_expected: 0,
                eeprom_input: [],
                eeprom_output: []
              ]

  @doc "Detects and initializes the backup device named by a standard ROM signature."
  def new(rom, opts \\ []) when is_binary(rom) and is_list(opts) do
    type = detect(rom)
    size = backup_size(type)

    with {:ok, binary} <- initial_data(size, Keyword.get(opts, :save_data)) do
      data = if size == 0, do: nil, else: Region.from_binary(binary)
      {:ok, %__MODULE__{type: type, data: data}}
    end
  end

  @doc "Returns the backup type detected from Nintendo library signatures."
  def detect(rom) when is_binary(rom) do
    cond do
      signature?(rom, "FLASH1M_") -> :flash1m
      signature?(rom, "FLASH512_") -> :flash512
      signature?(rom, "FLASH_") -> :flash512
      signature?(rom, "SRAM_") -> :sram
      signature?(rom, "EEPROM_") -> :eeprom
      true -> :none
    end
  end

  @doc "Returns the packed backup bytes."
  def to_binary(%__MODULE__{data: nil}), do: <<>>
  def to_binary(%__MODULE__{data: data}), do: Region.to_binary(data)

  @doc "Reads an SRAM or Flash byte."
  def read_byte(%__MODULE__{type: :none}, _address), do: 0xFF

  def read_byte(%__MODULE__{type: :sram, data: data}, address),
    do: Region.read(data, address &&& 0x7FFF)

  def read_byte(%__MODULE__{type: type, flash_id?: true}, address)
      when type in [:flash512, :flash1m] do
    case address &&& 0xFFFF do
      0 -> manufacturer_id(type)
      1 -> device_id(type)
      _offset -> 0xFF
    end
  end

  def read_byte(%__MODULE__{type: type, data: data, flash_bank: bank}, address)
      when type in [:flash512, :flash1m],
      do: Region.read(data, bank * 0x1_0000 + (address &&& 0xFFFF))

  def read_byte(%__MODULE__{}, _address), do: 0xFF

  @doc "Writes an SRAM byte or advances the Flash command state machine."
  def write_byte(%__MODULE__{type: :sram, data: data} = backup, address, value),
    do: %{backup | data: Region.write(data, address &&& 0x7FFF, value)}

  def write_byte(%__MODULE__{type: type} = backup, address, value)
      when type in [:flash512, :flash1m] do
    write_flash(backup, address &&& 0xFFFF, value)
  end

  def write_byte(%__MODULE__{} = backup, _address, _value), do: backup

  @doc "Begins a DMA-sized serial EEPROM command."
  def begin_eeprom_write(%__MODULE__{type: :eeprom} = backup, count) do
    address_bits = if count in [9, 73], do: 6, else: 14

    %{
      backup
      | eeprom_address_bits: address_bits,
        eeprom_expected: count,
        eeprom_input: []
    }
  end

  def begin_eeprom_write(%__MODULE__{} = backup, _count), do: backup

  @doc "Consumes one serial EEPROM command bit."
  def write_eeprom_bit(%__MODULE__{type: :eeprom} = backup, value) do
    input = backup.eeprom_input ++ [value &&& 1]
    backup = %{backup | eeprom_input: input}

    if length(input) == backup.eeprom_expected,
      do: finish_eeprom_command(backup),
      else: backup
  end

  def write_eeprom_bit(%__MODULE__{} = backup, _value), do: backup

  @doc "Produces and consumes one serial EEPROM response bit."
  def read_eeprom_bit(%__MODULE__{type: :eeprom, eeprom_output: [bit | rest]} = backup),
    do: {bit, %{backup | eeprom_output: rest}}

  def read_eeprom_bit(%__MODULE__{type: :eeprom} = backup), do: {1, backup}
  def read_eeprom_bit(%__MODULE__{} = backup), do: {1, backup}

  defp write_flash(%__MODULE__{} = backup, _address, 0xF0),
    do: %{backup | flash_state: :ready, flash_id?: false}

  defp write_flash(%__MODULE__{flash_state: :ready} = backup, 0x5555, 0xAA),
    do: %{backup | flash_state: :unlock_1}

  defp write_flash(%__MODULE__{flash_state: :unlock_1} = backup, 0x2AAA, 0x55),
    do: %{backup | flash_state: :unlock_2}

  defp write_flash(%__MODULE__{flash_state: :unlock_2} = backup, 0x5555, command) do
    case command do
      0x80 -> %{backup | flash_state: :erase_unlock_1}
      0x90 -> %{backup | flash_state: :ready, flash_id?: true}
      0xA0 -> %{backup | flash_state: :program}
      0xB0 -> %{backup | flash_state: :bank}
      _other -> %{backup | flash_state: :ready}
    end
  end

  defp write_flash(%__MODULE__{flash_state: :erase_unlock_1} = backup, 0x5555, 0xAA),
    do: %{backup | flash_state: :erase_unlock_2}

  defp write_flash(%__MODULE__{flash_state: :erase_unlock_2} = backup, 0x2AAA, 0x55),
    do: %{backup | flash_state: :erase_command}

  defp write_flash(%__MODULE__{flash_state: :erase_command} = backup, 0x5555, 0x10),
    do: %{backup | data: erased_region(backup), flash_state: :ready}

  defp write_flash(%__MODULE__{flash_state: :erase_command} = backup, address, 0x30) do
    offset = backup.flash_bank * 0x1_0000 + (address &&& 0xF000)
    data = Region.write_binary(backup.data, offset, :binary.copy(<<0xFF>>, 0x1000))
    %{backup | data: data, flash_state: :ready}
  end

  defp write_flash(%__MODULE__{flash_state: :program} = backup, address, value) do
    offset = backup.flash_bank * 0x1_0000 + address
    value = Region.read(backup.data, offset) &&& value
    %{backup | data: Region.write(backup.data, offset, value), flash_state: :ready}
  end

  defp write_flash(%__MODULE__{type: :flash1m, flash_state: :bank} = backup, 0, value),
    do: %{backup | flash_bank: value &&& 1, flash_state: :ready}

  defp write_flash(%__MODULE__{flash_state: :bank} = backup, _address, _value),
    do: %{backup | flash_bank: 0, flash_state: :ready}

  defp write_flash(%__MODULE__{} = backup, _address, _value),
    do: %{backup | flash_state: :ready}

  defp erased_region(%__MODULE__{type: type}),
    do: Region.from_binary(:binary.copy(<<0xFF>>, backup_size(type)))

  defp finish_eeprom_command(%__MODULE__{eeprom_input: [1, command | bits]} = backup) do
    {address_bits, payload} = Enum.split(bits, backup.eeprom_address_bits)
    block = bits_to_integer(address_bits) &&& 0x3FF

    case command do
      0 -> finish_eeprom_write(backup, block, payload)
      1 -> finish_eeprom_read(backup, block)
    end
  end

  defp finish_eeprom_command(backup),
    do: %{backup | eeprom_expected: 0, eeprom_input: []}

  defp finish_eeprom_write(backup, block, payload) do
    {data_bits, _stop} = Enum.split(payload, 64)

    binary =
      data_bits |> Enum.chunk_every(8) |> Enum.map(&bits_to_integer/1) |> :binary.list_to_bin()

    data = Region.write_binary(backup.data, block * 8, binary)
    %{backup | data: data, eeprom_expected: 0, eeprom_input: [], eeprom_output: []}
  end

  defp finish_eeprom_read(backup, block) do
    output = [0, 0, 0, 0] ++ binary_bits(Region.read_binary(backup.data, block * 8, 8))
    %{backup | eeprom_expected: 0, eeprom_input: [], eeprom_output: output}
  end

  defp binary_bits(binary) do
    for <<byte <- binary>>, bit <- 7..0//-1, do: byte >>> bit &&& 1
  end

  defp bits_to_integer(bits), do: Enum.reduce(bits, 0, fn bit, value -> value <<< 1 ||| bit end)

  defp initial_data(0, nil), do: {:ok, <<>>}
  defp initial_data(size, nil), do: {:ok, :binary.copy(<<0xFF>>, size)}

  defp initial_data(size, binary) when is_binary(binary) and byte_size(binary) == size,
    do: {:ok, binary}

  defp initial_data(size, binary) when is_binary(binary),
    do: {:error, {:invalid_save_size, size, byte_size(binary)}}

  defp initial_data(_size, _value), do: {:error, :invalid_save_data}

  defp backup_size(:none), do: 0
  defp backup_size(:sram), do: @sram_size
  defp backup_size(:flash512), do: @flash512_size
  defp backup_size(:flash1m), do: @flash1m_size
  defp backup_size(:eeprom), do: @eeprom_size

  defp manufacturer_id(:flash512), do: 0x32
  defp manufacturer_id(:flash1m), do: 0x62
  defp device_id(:flash512), do: 0x1B
  defp device_id(:flash1m), do: 0x13

  defp signature?(rom, signature), do: :binary.match(rom, signature) != :nomatch
end
