defmodule Beamicom.GB.Cartridge do
  @moduledoc """
  Loads Game Boy cartridges and provides their CPU-visible address windows.

  ROM-only, MBC1, MBC2, MBC3 (including RTC), and MBC5 cartridges are
  supported. Each bank controller has a dedicated compact struct. Bank writes
  precompute wrapped ROM offsets and external-RAM page offsets, while reads use
  static struct-matching function heads and direct indexed lookups—there is no
  protocol or run-time mapper-module lookup on the CPU read path. Live RAM is
  split into 256-byte pages so a byte write never copies the full save image.

  MBC3 time is deterministic. `advance_rtc/2` is the only way emulated time
  advances; reads never consult wall-clock time. Initial persistent state can
  be supplied with the `:persistence` load option, and extracted with
  `persistent_data/1`.
  """

  import Bitwise

  alias Beamicom.GB.Header
  alias Beamicom.GB.Cartridge.{MBC1, MBC2, MBC3, MBC5, RAM}

  @enforce_keys [:header, :rom, :ram, :ram_mask]
  defstruct @enforce_keys

  @type t :: %__MODULE__{} | MBC1.t() | MBC2.t() | MBC3.t() | MBC5.t()

  @compile {:inline, read: 2}

  @doc """
  Loads and validates a cartridge image.

  `:persistence` may be a map returned by `persistent_data/1`. The `:ram`
  and `:rtc` options can instead inject those values independently.
  """
  @spec load(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(rom, opts \\ []) do
    with {:ok, header} <- Header.parse(rom, opts),
         :ok <- validate_rom_length(header, rom),
         {:ok, cartridge} <- build(header, rom, opts) do
      {:ok, cartridge}
    end
  end

  @doc "Alias for `load/2`, useful at media-parsing call sites."
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(rom, opts \\ []), do: load(rom, opts)

  @doc "Reads a byte from a cartridge-owned address, or `$FF` when unmapped."
  @spec read(t(), 0..0xFFFF) :: byte()
  def read(%__MODULE__{rom: rom}, address) when address in 0x0000..0x7FFF,
    do: :binary.at(rom, address)

  def read(%__MODULE__{ram: %RAM{size: 0}}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%__MODULE__{ram: ram, ram_mask: mask}, address) when address in 0xA000..0xBFFF,
    do: RAM.read(ram, address - 0xA000 &&& mask)

  def read(%MBC1{rom: rom, rom0_offset: offset}, address) when address in 0x0000..0x3FFF,
    do: :binary.at(rom, offset + address)

  def read(%MBC1{rom: rom, romx_offset: offset}, address) when address in 0x4000..0x7FFF,
    do: :binary.at(rom, offset + address - 0x4000)

  def read(%MBC1{ram_enabled: false}, address) when address in 0xA000..0xBFFF, do: 0xFF
  def read(%MBC1{ram: %RAM{size: 0}}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%MBC1{ram: ram, ram_page_offset: page_offset, ram_mask: mask}, address)
      when address in 0xA000..0xBFFF,
      do: RAM.read_window(ram, page_offset, address - 0xA000 &&& mask)

  def read(%MBC2{rom: rom}, address) when address in 0x0000..0x3FFF,
    do: :binary.at(rom, address)

  def read(%MBC2{rom: rom, romx_offset: offset}, address) when address in 0x4000..0x7FFF,
    do: :binary.at(rom, offset + address - 0x4000)

  def read(%MBC2{ram_enabled: false}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%MBC2{ram: ram}, address) when address in 0xA000..0xBFFF,
    do: 0xF0 ||| RAM.read(ram, address &&& 0x01FF)

  def read(%MBC3{rom: rom}, address) when address in 0x0000..0x3FFF,
    do: :binary.at(rom, address)

  def read(%MBC3{rom: rom, romx_offset: offset}, address) when address in 0x4000..0x7FFF,
    do: :binary.at(rom, offset + address - 0x4000)

  def read(%MBC3{ram_enabled: false}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%MBC3{selection: :ram, ram: %RAM{size: 0}}, address)
      when address in 0xA000..0xBFFF,
      do: 0xFF

  def read(%MBC3{selection: :ram, ram: ram, ram_page_offset: page_offset}, address)
      when address in 0xA000..0xBFFF,
      do: RAM.read_window(ram, page_offset, address - 0xA000)

  def read(%MBC3{selection: :rtc, rtc: %MBC3.RTC{} = rtc} = cartridge, address)
      when address in 0xA000..0xBFFF,
      do: MBC3.RTC.read(cartridge.latched_rtc || rtc, cartridge.rtc_register)

  def read(%MBC3{}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%MBC5{rom: rom}, address) when address in 0x0000..0x3FFF,
    do: :binary.at(rom, address)

  def read(%MBC5{rom: rom, romx_offset: offset}, address) when address in 0x4000..0x7FFF,
    do: :binary.at(rom, offset + address - 0x4000)

  def read(%MBC5{ram_enabled: false}, address) when address in 0xA000..0xBFFF, do: 0xFF
  def read(%MBC5{ram: %RAM{size: 0}}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%MBC5{ram: ram, ram_page_offset: page_offset}, address)
      when address in 0xA000..0xBFFF,
      do: RAM.read_window(ram, page_offset, address - 0xA000)

  def read(cartridge, address) when is_struct(cartridge) and address in 0x0000..0xFFFF, do: 0xFF

  @doc "Writes a byte to cartridge RAM or mapper registers."
  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%MBC1{} = cartridge, address, value), do: MBC1.write(cartridge, address, value)
  def write(%MBC2{} = cartridge, address, value), do: MBC2.write(cartridge, address, value)
  def write(%MBC3{} = cartridge, address, value), do: MBC3.write(cartridge, address, value)
  def write(%MBC5{} = cartridge, address, value), do: MBC5.write(cartridge, address, value)

  def write(%__MODULE__{ram: %RAM{size: 0}} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  def write(%__MODULE__{ram: ram, ram_mask: mask} = cartridge, address, value)
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    offset = address - 0xA000 &&& mask
    put_ram(cartridge, ram, offset, value)
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  @doc "Advances an MBC3 RTC by an explicitly supplied number of seconds."
  @spec advance_rtc(t(), non_neg_integer()) :: t()
  def advance_rtc(%MBC3{} = cartridge, seconds), do: MBC3.advance_rtc(cartridge, seconds)
  def advance_rtc(cartridge, seconds) when is_struct(cartridge) and seconds >= 0, do: cartridge

  @doc "Returns deterministic battery-backed RAM and RTC data."
  @spec persistent_data(t()) :: %{required(:ram) => binary(), optional(:rtc) => map()}
  def persistent_data(%MBC3{ram: ram, rtc: %MBC3.RTC{} = rtc}),
    do: %{ram: RAM.to_binary(ram), rtc: MBC3.RTC.to_map(rtc)}

  def persistent_data(%{ram: %RAM{} = ram}), do: %{ram: RAM.to_binary(ram)}

  @doc "Restores data produced by `persistent_data/1` without consulting a clock."
  @spec restore_persistent_data(t(), map()) :: {:ok, t()} | {:error, term()}
  def restore_persistent_data(%MBC3{} = cartridge, data),
    do: MBC3.restore_persistent_data(cartridge, data)

  def restore_persistent_data(%{ram: %RAM{} = ram} = cartridge, %{ram: saved_ram})
      when is_binary(saved_ram) do
    if RAM.size(ram) == byte_size(saved_ram) do
      {:ok, %{cartridge | ram: RAM.new(saved_ram)}}
    else
      {:error, {:ram_size_mismatch, RAM.size(ram), byte_size(saved_ram)}}
    end
  end

  def restore_persistent_data(cartridge, _data) when is_struct(cartridge),
    do: {:error, :invalid_persistence_data}

  defp build(%Header{mapper: :rom_only} = header, rom, opts) do
    with :ok <- validate_rom_only(header),
         {:ok, ram} <- initial_ram(header.ram_size, opts) do
      {:ok,
       %__MODULE__{
         header: header,
         rom: rom,
         ram: ram,
         ram_mask: max(RAM.size(ram) - 1, 0)
       }}
    end
  end

  defp build(%Header{mapper: :mbc1} = header, rom, opts) do
    with :ok <- validate_declared_ram(header),
         {:ok, ram} <- initial_ram(header.ram_size, opts),
         do: MBC1.new(header, rom, ram)
  end

  defp build(%Header{mapper: :mbc2} = header, rom, opts) do
    with :ok <- validate_mbc2(header),
         {:ok, ram} <- initial_ram(512, opts),
         do: MBC2.new(header, rom, ram)
  end

  defp build(%Header{mapper: :mbc3} = header, rom, opts) do
    with :ok <- validate_declared_ram(header),
         {:ok, ram} <- initial_ram(header.ram_size, opts),
         do: MBC3.new(header, rom, ram, opts)
  end

  defp build(%Header{mapper: :mbc5} = header, rom, opts) do
    with :ok <- validate_declared_ram(header),
         {:ok, ram} <- initial_ram(header.ram_size, opts),
         do: MBC5.new(header, rom, ram)
  end

  defp build(%Header{mapper: mapper}, _rom, _opts), do: {:error, {:unsupported_mapper, mapper}}

  defp validate_rom_length(%Header{rom_size: size}, rom) when byte_size(rom) == size, do: :ok

  defp validate_rom_length(%Header{rom_size: expected}, rom),
    do: {:error, {:rom_size_mismatch, expected, byte_size(rom)}}

  defp validate_rom_only(%Header{rom_banks: banks}) when banks != 2,
    do: {:error, {:unsupported_rom_only_bank_count, banks}}

  defp validate_rom_only(%Header{} = header) do
    with :ok <- validate_declared_ram(header) do
      if header.ram_size <= 0x2000,
        do: :ok,
        else: {:error, {:unsupported_rom_only_ram_size, header.ram_size}}
    end
  end

  defp validate_declared_ram(%Header{features: features, ram_size: ram_size}) do
    has_ram? = :ram in features

    cond do
      has_ram? and ram_size == 0 -> {:error, :missing_ram_size}
      not has_ram? and ram_size != 0 -> {:error, {:unexpected_ram_size, ram_size}}
      true -> :ok
    end
  end

  defp validate_mbc2(%Header{ram_size: 0}), do: :ok
  defp validate_mbc2(%Header{ram_size: size}), do: {:error, {:unexpected_ram_size, size}}

  defp initial_ram(size, opts) do
    persistence = Keyword.get(opts, :persistence, %{})

    if is_map(persistence) do
      ram = Keyword.get(opts, :ram, Map.get(persistence, :ram, :binary.copy(<<0>>, size)))

      if is_binary(ram) and byte_size(ram) == size do
        {:ok, RAM.new(ram)}
      else
        actual = if is_binary(ram), do: byte_size(ram), else: :invalid
        {:error, {:ram_size_mismatch, size, actual}}
      end
    else
      {:error, :invalid_persistence_data}
    end
  end

  defp put_ram(cartridge, ram, offset, value) do
    case RAM.put(ram, offset, value) do
      :unchanged -> cartridge
      {:changed, ram} -> %{cartridge | ram: ram}
    end
  end
end
