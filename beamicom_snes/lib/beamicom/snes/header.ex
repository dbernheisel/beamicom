defmodule Beamicom.SNES.Header do
  @moduledoc """
  Metadata from the 32-byte internal SNES cartridge header.

  The same structure resides at a different file offset for LoROM, HiROM, and
  ExHiROM. `Beamicom.SNES.Cartridge` owns candidate selection because mapping
  knowledge is required to decide which copy is authoritative.
  """

  import Bitwise

  @enforce_keys [
    :layout,
    :offset,
    :title,
    :map_mode,
    :fast_rom?,
    :cartridge_type,
    :rom_size_code,
    :declared_rom_size,
    :ram_size_code,
    :declared_ram_size,
    :destination_code,
    :region,
    :developer_id,
    :version,
    :checksum,
    :checksum_complement,
    :reset_vector
  ]
  defstruct @enforce_keys

  @type layout :: :lorom | :hirom | :exhirom
  @type region :: :ntsc | :pal
  @type t :: %__MODULE__{}

  @spec parse(binary(), layout(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def parse(rom, layout, offset)
      when is_binary(rom) and layout in [:lorom, :hirom, :exhirom] and
             is_integer(offset) and offset >= 0 do
    if byte_size(rom) < offset + 0x40 do
      {:error, {:header_out_of_bounds, offset}}
    else
      title = binary_part(rom, offset, 21) |> trim_title()
      map_mode = :binary.at(rom, offset + 0x15)
      rom_size_code = :binary.at(rom, offset + 0x17)
      ram_size_code = :binary.at(rom, offset + 0x18)
      destination_code = :binary.at(rom, offset + 0x19)

      {:ok,
       %__MODULE__{
         layout: layout,
         offset: offset,
         title: title,
         map_mode: map_mode,
         fast_rom?: (map_mode &&& 0x10) != 0,
         cartridge_type: :binary.at(rom, offset + 0x16),
         rom_size_code: rom_size_code,
         declared_rom_size: size_from_code(rom_size_code),
         ram_size_code: ram_size_code,
         declared_ram_size: if(ram_size_code == 0, do: 0, else: size_from_code(ram_size_code)),
         destination_code: destination_code,
         region: region(destination_code),
         developer_id: :binary.at(rom, offset + 0x1A),
         version: :binary.at(rom, offset + 0x1B),
         checksum_complement: little16(rom, offset + 0x1C),
         checksum: little16(rom, offset + 0x1E),
         reset_vector: little16(rom, offset + 0x3C)
       }}
    end
  end

  def parse(_rom, _layout, _offset), do: {:error, :invalid_header}

  @doc "Whether the header's map-mode byte agrees with its candidate location."
  @spec layout_matches?(t()) :: boolean()
  def layout_matches?(%__MODULE__{layout: :lorom, map_mode: mode}),
    do: (mode &&& 0x0F) in [0x00, 0x02, 0x03]

  def layout_matches?(%__MODULE__{layout: :hirom, map_mode: mode}),
    do: (mode &&& 0x0F) == 0x01

  def layout_matches?(%__MODULE__{layout: :exhirom, map_mode: mode}),
    do: (mode &&& 0x0F) == 0x05

  @doc "Scores a candidate without requiring a valid historical checksum."
  @spec score(t()) :: integer()
  def score(%__MODULE__{} = header) do
    if(layout_matches?(header), do: 8, else: 0) +
      if(bxor(header.checksum, header.checksum_complement) == 0xFFFF, do: 8, else: 0) +
      if(header.reset_vector >= 0x8000, do: 4, else: 0) +
      if printable_title?(header.title), do: 2, else: 0
  end

  defp little16(binary, offset),
    do: :binary.at(binary, offset) ||| :binary.at(binary, offset + 1) <<< 8

  defp size_from_code(code) when code < 0x20, do: 1024 <<< code
  defp size_from_code(_code), do: nil

  # Destination codes $02-$0C are the historically PAL territories. Japan,
  # North America, Korea, and the later extended codes use NTSC timing.
  defp region(code) when code in 0x02..0x0C, do: :pal
  defp region(_code), do: :ntsc

  defp printable_title?(<<>>), do: false

  defp printable_title?(title) do
    Enum.all?(:binary.bin_to_list(title), &(&1 in 0x20..0x7E))
  end

  defp trim_title(<<>>), do: <<>>

  defp trim_title(title) do
    if :binary.last(title) in [0x00, 0x20, 0xFF] do
      title |> binary_part(0, byte_size(title) - 1) |> trim_title()
    else
      title
    end
  end
end
