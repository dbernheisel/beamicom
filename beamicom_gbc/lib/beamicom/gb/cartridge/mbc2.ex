defmodule Beamicom.GB.Cartridge.MBC2 do
  @moduledoc "MBC2 ROM banking and built-in 512 x 4-bit RAM."

  import Bitwise
  alias Beamicom.GB.Cartridge.RAM
  alias Beamicom.GB.Header

  @enforce_keys [:header, :rom, :ram, :rom_banks, :romx_offset]
  defstruct @enforce_keys ++ [ram_enabled: false, rom_bank: 1]

  @type t :: %__MODULE__{}

  @spec new(Header.t(), binary(), RAM.t()) :: {:ok, t()} | {:error, term()}
  def new(%Header{} = header, rom, ram) do
    if header.rom_banks <= 16 do
      {:ok,
       %__MODULE__{
         header: header,
         rom: rom,
         ram: ram,
         rom_banks: header.rom_banks,
         romx_offset: rem(1, header.rom_banks) * 0x4000
       }}
    else
      {:error, {:unsupported_mbc2_rom_banks, header.rom_banks}}
    end
  end

  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{ram_enabled: enabled} = cartridge, address, value)
      when address in 0x0000..0x3FFF and (address &&& 0x0100) == 0 do
    next = (value &&& 0x0F) == 0x0A
    if enabled == next, do: cartridge, else: %{cartridge | ram_enabled: next}
  end

  def write(%__MODULE__{rom_bank: current} = cartridge, address, value)
      when address in 0x0000..0x3FFF do
    bank = value &&& 0x0F
    bank = if bank == 0, do: 1, else: bank

    if bank == current do
      cartridge
    else
      %{cartridge | rom_bank: bank, romx_offset: rem(bank, cartridge.rom_banks) * 0x4000}
    end
  end

  def write(%__MODULE__{ram_enabled: false} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(%__MODULE__{ram: ram} = cartridge, address, value)
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    offset = address &&& 0x01FF
    put_ram(cartridge, ram, offset, value &&& 0x0F)
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  defp put_ram(cartridge, ram, offset, value) do
    case RAM.put(ram, offset, value) do
      :unchanged -> cartridge
      {:changed, ram} -> %{cartridge | ram: ram}
    end
  end
end
