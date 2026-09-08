defmodule Beamicom.GB.Cartridge.MBC1 do
  @moduledoc "MBC1 bank registers and precomputed ROM/RAM window offsets."

  import Bitwise
  alias Beamicom.GB.Cartridge.RAM
  alias Beamicom.GB.Header

  @enforce_keys [
    :header,
    :rom,
    :ram,
    :rom_banks,
    :ram_banks,
    :ram_mask,
    :rom0_offset,
    :romx_offset,
    :ram_page_offset
  ]
  defstruct @enforce_keys ++ [ram_enabled: false, rom_bank_low: 1, bank_high: 0, mode: 0]

  @type t :: %__MODULE__{}

  @spec new(Header.t(), binary(), RAM.t()) :: {:ok, t()} | {:error, term()}
  def new(%Header{} = header, rom, ram) do
    cond do
      header.rom_banks > 128 ->
        {:error, {:unsupported_mbc1_rom_banks, header.rom_banks}}

      RAM.size(ram) > 32 * 1024 ->
        {:error, {:unsupported_mbc1_ram_size, RAM.size(ram)}}

      header.rom_banks > 32 and RAM.size(ram) > 8 * 1024 ->
        {:error, {:unsupported_mbc1_rom_ram_combination, header.rom_banks, RAM.size(ram)}}

      true ->
        {:ok,
         %__MODULE__{
           header: header,
           rom: rom,
           ram: ram,
           rom_banks: header.rom_banks,
           ram_banks: div(RAM.size(ram) + 0x1FFF, 0x2000),
           ram_mask: min(max(RAM.size(ram), 1), 0x2000) - 1,
           rom0_offset: 0,
           romx_offset: wrap_bank(1, header.rom_banks) * 0x4000,
           ram_page_offset: 0
         }}
    end
  end

  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{ram: %RAM{size: 0}} = cartridge, address, _value)
      when address in 0x0000..0x1FFF,
      do: cartridge

  def write(%__MODULE__{ram_enabled: enabled} = cartridge, address, value)
      when address in 0x0000..0x1FFF do
    next = (value &&& 0x0F) == 0x0A
    if enabled == next, do: cartridge, else: %{cartridge | ram_enabled: next}
  end

  def write(%__MODULE__{rom_bank_low: current} = cartridge, address, value)
      when address in 0x2000..0x3FFF do
    bank = value &&& 0x1F
    bank = if bank == 0, do: 1, else: bank
    if bank == current, do: cartridge, else: recalculate(%{cartridge | rom_bank_low: bank})
  end

  def write(%__MODULE__{bank_high: current} = cartridge, address, value)
      when address in 0x4000..0x5FFF do
    bank = value &&& 0x03
    if bank == current, do: cartridge, else: recalculate(%{cartridge | bank_high: bank})
  end

  def write(%__MODULE__{mode: current} = cartridge, address, value)
      when address in 0x6000..0x7FFF do
    mode = value &&& 0x01
    if mode == current, do: cartridge, else: recalculate(%{cartridge | mode: mode})
  end

  def write(%__MODULE__{ram_enabled: false} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(%__MODULE__{ram: %RAM{size: 0}} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(
        %__MODULE__{ram: ram, ram_page_offset: page_offset, ram_mask: mask} = cartridge,
        address,
        value
      )
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    put_ram(cartridge, ram, page_offset, address - 0xA000 &&& mask, value)
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  defp recalculate(cartridge) do
    high = cartridge.bank_high <<< 5
    rom0_bank = if cartridge.mode == 1, do: high, else: 0
    romx_bank = high ||| cartridge.rom_bank_low
    ram_bank = if cartridge.mode == 1, do: cartridge.bank_high, else: 0

    %{
      cartridge
      | rom0_offset: wrap_bank(rom0_bank, cartridge.rom_banks) * 0x4000,
        romx_offset: wrap_bank(romx_bank, cartridge.rom_banks) * 0x4000,
        ram_page_offset: wrap_bank(ram_bank, cartridge.ram_banks) * 32
    }
  end

  defp wrap_bank(_bank, 0), do: 0
  defp wrap_bank(bank, count), do: rem(bank, count)

  defp put_ram(cartridge, ram, page_offset, window_offset, value) do
    case RAM.put_window(ram, page_offset, window_offset, value) do
      :unchanged -> cartridge
      {:changed, ram} -> %{cartridge | ram: ram}
    end
  end
end
