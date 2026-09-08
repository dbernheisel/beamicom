defmodule Beamicom.GB.Header do
  @moduledoc """
  Parses the cartridge header embedded in a Game Boy ROM image.

  `parse/2` validates the header checksum by default and returns normalized
  cartridge, mapper, ROM-size, and RAM-size metadata. Parsing a header does not
  imply that the emulator implements its mapper; that decision belongs to
  `Beamicom.GB.Cartridge`.

  Set `validate_checksum: false` when inspecting a damaged image. The returned
  `header_checksum_valid?` field still records the result.

  The title is returned as a binary with trailing NUL and space padding removed.
  DMG headers use the historical 16-byte field. CGB-aware headers reserve the
  last byte for the CGB flag and therefore allow 15 title bytes; newer headers
  whose old licensee byte selects the new-licensee layout also reserve four
  bytes for the manufacturer code and allow 11 title bytes.

  ## References

  * Pan Docs, The Cartridge Header: https://gbdev.io/pandocs/The_Cartridge_Header.html
  * Pan Docs, MBCs: https://gbdev.io/pandocs/MBCs.html
  """

  import Bitwise

  @header_end 0x150
  @title_offset 0x134
  @cgb_flag_offset 0x143
  @cartridge_type_offset 0x147
  @rom_size_offset 0x148
  @ram_size_offset 0x149
  @old_licensee_offset 0x14B
  @checksum_offset 0x14D

  @enforce_keys [
    :title,
    :cgb_flag,
    :cgb_mode,
    :cartridge_type_code,
    :cartridge_type,
    :mapper,
    :features,
    :rom_size_code,
    :rom_size,
    :rom_banks,
    :ram_size_code,
    :ram_size,
    :ram_banks,
    :header_checksum,
    :calculated_header_checksum,
    :header_checksum_valid?
  ]
  defstruct @enforce_keys

  @type cgb_mode :: :dmg_only | :cgb_compatible | :cgb_only
  @type mapper :: :rom_only | :mbc1 | :mbc2 | :mmm01 | :mbc3 | :mbc5 | atom()

  @type t :: %__MODULE__{
          title: binary(),
          cgb_flag: byte(),
          cgb_mode: cgb_mode(),
          cartridge_type_code: byte(),
          cartridge_type: atom(),
          mapper: mapper(),
          features: [atom()],
          rom_size_code: byte(),
          rom_size: non_neg_integer(),
          rom_banks: non_neg_integer(),
          ram_size_code: byte(),
          ram_size: non_neg_integer(),
          ram_banks: non_neg_integer(),
          header_checksum: byte(),
          calculated_header_checksum: byte(),
          header_checksum_valid?: boolean()
        }

  @doc """
  Parses header metadata from a complete ROM image.

  Returns a descriptive error for a short image, an unknown cartridge or size
  code, or an invalid header checksum. This function only needs the first
  `0x150` bytes; declared ROM length is checked when loading a cartridge.
  """
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(rom, opts \\ [])

  def parse(rom, opts) when is_binary(rom) and is_list(opts) do
    if byte_size(rom) < @header_end do
      {:error, {:rom_too_small, @header_end, byte_size(rom)}}
    else
      parse_header(rom, Keyword.get(opts, :validate_checksum, true))
    end
  end

  def parse(_rom, _opts), do: {:error, :invalid_rom}

  @doc "Calculates the checksum for header bytes `$0134..$014C`."
  @spec calculate_checksum(binary()) :: {:ok, byte()} | {:error, term()}
  def calculate_checksum(rom) when is_binary(rom) and byte_size(rom) >= @header_end do
    checksum =
      rom
      |> binary_part(@title_offset, @checksum_offset - @title_offset)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    {:ok, checksum}
  end

  def calculate_checksum(rom) when is_binary(rom),
    do: {:error, {:rom_too_small, @header_end, byte_size(rom)}}

  def calculate_checksum(_rom), do: {:error, :invalid_rom}

  defp parse_header(rom, validate_checksum?) do
    cgb_flag = :binary.at(rom, @cgb_flag_offset)
    type_code = :binary.at(rom, @cartridge_type_offset)
    rom_size_code = :binary.at(rom, @rom_size_offset)
    ram_size_code = :binary.at(rom, @ram_size_offset)
    actual_checksum = :binary.at(rom, @checksum_offset)
    {:ok, calculated_checksum} = calculate_checksum(rom)

    with {:ok, {cartridge_type, mapper, features}} <- cartridge_type(type_code),
         {:ok, {rom_size, rom_banks}} <- rom_size(rom_size_code),
         {:ok, {ram_size, ram_banks}} <- ram_size(ram_size_code),
         :ok <- validate_checksum(validate_checksum?, calculated_checksum, actual_checksum) do
      {:ok,
       %__MODULE__{
         title: title(rom, cgb_flag),
         cgb_flag: cgb_flag,
         cgb_mode: cgb_mode(cgb_flag),
         cartridge_type_code: type_code,
         cartridge_type: cartridge_type,
         mapper: mapper,
         features: features,
         rom_size_code: rom_size_code,
         rom_size: rom_size,
         rom_banks: rom_banks,
         ram_size_code: ram_size_code,
         ram_size: ram_size,
         ram_banks: ram_banks,
         header_checksum: actual_checksum,
         calculated_header_checksum: calculated_checksum,
         header_checksum_valid?: actual_checksum == calculated_checksum
       }}
    end
  end

  defp title(rom, cgb_flag) do
    rom
    |> binary_part(@title_offset, title_length(rom, cgb_flag))
    |> trim_title()
  end

  # In CGB-aware headers $0143 is always the mode flag, reducing the legacy
  # title to 15 bytes. The $33 old-licensee marker identifies the newer header
  # layout where $013F..$0142 are a manufacturer code rather than title bytes.
  defp title_length(_rom, cgb_flag) when (cgb_flag &&& 0x80) == 0, do: 16

  defp title_length(rom, _cgb_flag) do
    if :binary.at(rom, @old_licensee_offset) == 0x33, do: 11, else: 15
  end

  defp trim_title(<<>>), do: <<>>

  defp trim_title(title) do
    if :binary.last(title) in [0x00, 0x20] do
      title |> binary_part(0, byte_size(title) - 1) |> trim_title()
    else
      title
    end
  end

  defp cgb_mode(flag) when (flag &&& 0x80) == 0, do: :dmg_only
  defp cgb_mode(flag) when (flag &&& 0x40) != 0, do: :cgb_only
  defp cgb_mode(_flag), do: :cgb_compatible

  defp validate_checksum(false, _calculated, _actual), do: :ok
  defp validate_checksum(true, checksum, checksum), do: :ok

  defp validate_checksum(true, calculated, actual),
    do: {:error, {:invalid_header_checksum, calculated, actual}}

  defp cartridge_type(0x00), do: {:ok, {:rom_only, :rom_only, []}}
  defp cartridge_type(0x01), do: {:ok, {:mbc1, :mbc1, []}}
  defp cartridge_type(0x02), do: {:ok, {:mbc1_ram, :mbc1, [:ram]}}
  defp cartridge_type(0x03), do: {:ok, {:mbc1_ram_battery, :mbc1, [:ram, :battery]}}
  defp cartridge_type(0x05), do: {:ok, {:mbc2, :mbc2, [:ram]}}
  defp cartridge_type(0x06), do: {:ok, {:mbc2_battery, :mbc2, [:ram, :battery]}}
  defp cartridge_type(0x08), do: {:ok, {:rom_ram, :rom_only, [:ram]}}
  defp cartridge_type(0x09), do: {:ok, {:rom_ram_battery, :rom_only, [:ram, :battery]}}
  defp cartridge_type(0x0B), do: {:ok, {:mmm01, :mmm01, []}}
  defp cartridge_type(0x0C), do: {:ok, {:mmm01_ram, :mmm01, [:ram]}}
  defp cartridge_type(0x0D), do: {:ok, {:mmm01_ram_battery, :mmm01, [:ram, :battery]}}
  defp cartridge_type(0x0F), do: {:ok, {:mbc3_timer_battery, :mbc3, [:timer, :battery]}}

  defp cartridge_type(0x10),
    do: {:ok, {:mbc3_timer_ram_battery, :mbc3, [:timer, :ram, :battery]}}

  defp cartridge_type(0x11), do: {:ok, {:mbc3, :mbc3, []}}
  defp cartridge_type(0x12), do: {:ok, {:mbc3_ram, :mbc3, [:ram]}}
  defp cartridge_type(0x13), do: {:ok, {:mbc3_ram_battery, :mbc3, [:ram, :battery]}}
  defp cartridge_type(0x19), do: {:ok, {:mbc5, :mbc5, []}}
  defp cartridge_type(0x1A), do: {:ok, {:mbc5_ram, :mbc5, [:ram]}}
  defp cartridge_type(0x1B), do: {:ok, {:mbc5_ram_battery, :mbc5, [:ram, :battery]}}
  defp cartridge_type(0x1C), do: {:ok, {:mbc5_rumble, :mbc5, [:rumble]}}
  defp cartridge_type(0x1D), do: {:ok, {:mbc5_rumble_ram, :mbc5, [:rumble, :ram]}}

  defp cartridge_type(0x1E),
    do: {:ok, {:mbc5_rumble_ram_battery, :mbc5, [:rumble, :ram, :battery]}}

  defp cartridge_type(0x20), do: {:ok, {:mbc6, :mbc6, []}}

  defp cartridge_type(0x22),
    do: {:ok, {:mbc7_sensor_rumble_ram_battery, :mbc7, [:sensor, :rumble, :ram, :battery]}}

  defp cartridge_type(0xFC), do: {:ok, {:pocket_camera, :pocket_camera, [:camera]}}
  defp cartridge_type(0xFD), do: {:ok, {:bandai_tama5, :bandai_tama5, []}}
  defp cartridge_type(0xFE), do: {:ok, {:huc3, :huc3, []}}
  defp cartridge_type(0xFF), do: {:ok, {:huc1_ram_battery, :huc1, [:ram, :battery]}}
  defp cartridge_type(code), do: {:error, {:unknown_cartridge_type, code}}

  defp rom_size(0x00), do: {:ok, {32 * 1024, 2}}
  defp rom_size(0x01), do: {:ok, {64 * 1024, 4}}
  defp rom_size(0x02), do: {:ok, {128 * 1024, 8}}
  defp rom_size(0x03), do: {:ok, {256 * 1024, 16}}
  defp rom_size(0x04), do: {:ok, {512 * 1024, 32}}
  defp rom_size(0x05), do: {:ok, {1024 * 1024, 64}}
  defp rom_size(0x06), do: {:ok, {2 * 1024 * 1024, 128}}
  defp rom_size(0x07), do: {:ok, {4 * 1024 * 1024, 256}}
  defp rom_size(0x08), do: {:ok, {8 * 1024 * 1024, 512}}
  defp rom_size(0x52), do: {:ok, {72 * 16 * 1024, 72}}
  defp rom_size(0x53), do: {:ok, {80 * 16 * 1024, 80}}
  defp rom_size(0x54), do: {:ok, {96 * 16 * 1024, 96}}
  defp rom_size(code), do: {:error, {:unknown_rom_size, code}}

  defp ram_size(0x00), do: {:ok, {0, 0}}
  defp ram_size(0x01), do: {:ok, {2 * 1024, 1}}
  defp ram_size(0x02), do: {:ok, {8 * 1024, 1}}
  defp ram_size(0x03), do: {:ok, {32 * 1024, 4}}
  defp ram_size(0x04), do: {:ok, {128 * 1024, 16}}
  defp ram_size(0x05), do: {:ok, {64 * 1024, 8}}
  defp ram_size(code), do: {:error, {:unknown_ram_size, code}}
end
