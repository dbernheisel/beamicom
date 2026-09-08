defmodule Beamicom.GB.Cartridge.MBC5 do
  @moduledoc "MBC5 9-bit ROM banking, RAM banking, and rumble state."

  import Bitwise
  alias Beamicom.GB.Cartridge.RAM
  alias Beamicom.GB.Header

  @enforce_keys [
    :header,
    :rom,
    :ram,
    :rom_banks,
    :ram_banks,
    :ram_bank_mask,
    :romx_offset,
    :ram_page_offset
  ]
  defstruct @enforce_keys ++
              [ram_enabled: false, rom_bank_low: 1, rom_bank_high: 0, ram_bank: 0, rumble: false]

  @type t :: %__MODULE__{}

  @spec new(Header.t(), binary(), RAM.t()) :: {:ok, t()} | {:error, term()}
  def new(%Header{} = header, rom, ram) do
    rumble? = :rumble in header.features
    ram_banks = div(RAM.size(ram), 0x2000)

    cond do
      header.rom_banks > 512 ->
        {:error, {:unsupported_mbc5_rom_banks, header.rom_banks}}

      RAM.size(ram) > 128 * 1024 ->
        {:error, {:unsupported_mbc5_ram_size, RAM.size(ram)}}

      rumble? and RAM.size(ram) > 64 * 1024 ->
        {:error, {:unsupported_mbc5_rumble_ram_size, RAM.size(ram)}}

      true ->
        {:ok,
         %__MODULE__{
           header: header,
           rom: rom,
           ram: ram,
           rom_banks: header.rom_banks,
           ram_banks: ram_banks,
           ram_bank_mask: if(rumble?, do: 0x07, else: 0x0F),
           romx_offset: rem(1, header.rom_banks) * 0x4000,
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
      when address in 0x2000..0x2FFF do
    if value == current,
      do: cartridge,
      else: recalculate_rom(%{cartridge | rom_bank_low: value})
  end

  def write(%__MODULE__{rom_bank_high: current} = cartridge, address, value)
      when address in 0x3000..0x3FFF do
    high = value &&& 0x01

    if high == current,
      do: cartridge,
      else: recalculate_rom(%{cartridge | rom_bank_high: high})
  end

  def write(%__MODULE__{} = cartridge, address, value) when address in 0x4000..0x5FFF do
    bank = value &&& cartridge.ram_bank_mask
    rumble = cartridge.ram_bank_mask == 0x07 and (value &&& 0x08) != 0

    if bank == cartridge.ram_bank and rumble == cartridge.rumble do
      cartridge
    else
      page_offset = if cartridge.ram_banks == 0, do: 0, else: rem(bank, cartridge.ram_banks) * 32
      %{cartridge | ram_bank: bank, ram_page_offset: page_offset, rumble: rumble}
    end
  end

  def write(%__MODULE__{ram_enabled: false} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(%__MODULE__{ram: %RAM{size: 0}} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(%__MODULE__{ram: ram, ram_page_offset: page_offset} = cartridge, address, value)
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    put_ram(cartridge, ram, page_offset, address - 0xA000, value)
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  defp recalculate_rom(cartridge) do
    bank = cartridge.rom_bank_high <<< 8 ||| cartridge.rom_bank_low
    %{cartridge | romx_offset: rem(bank, cartridge.rom_banks) * 0x4000}
  end

  defp put_ram(cartridge, ram, page_offset, window_offset, value) do
    case RAM.put_window(ram, page_offset, window_offset, value) do
      :unchanged -> cartridge
      {:changed, ram} -> %{cartridge | ram: ram}
    end
  end
end
