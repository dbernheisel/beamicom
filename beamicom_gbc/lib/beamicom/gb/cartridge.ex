defmodule Beamicom.GB.Cartridge do
  @moduledoc """
  A loaded Game Boy cartridge and its mapper-owned state.

  This first implementation supports cartridges without a memory-bank
  controller: types `$00`, `$08`, and `$09`. Their two 16 KiB ROM banks are
  visible directly at `$0000..$7FFF`; optional external RAM is visible at
  `$A000..$BFFF`.

  `read/2` returns `$FF` outside those cartridge-owned address ranges, matching
  the value normally observed on an un-driven Game Boy bus. `write/3` updates
  external RAM and ignores other addresses. Both operations keep the API small
  enough for later MBC implementations to own banking registers and RAM-enable
  state without changing callers.
  """

  alias Beamicom.GB.Header

  @enforce_keys [:header, :rom, :ram]
  defstruct @enforce_keys

  @type t :: %__MODULE__{header: Header.t(), rom: binary(), ram: binary()}

  @doc "Loads and validates a no-MBC cartridge image."
  @spec load(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(rom, opts \\ []) do
    with {:ok, header} <- Header.parse(rom, opts),
         :ok <- validate_rom_length(header, rom),
         :ok <- validate_mapper(header),
         :ok <- validate_rom_only_size(header),
         :ok <- validate_ram_declaration(header) do
      {:ok,
       %__MODULE__{
         header: header,
         rom: rom,
         ram: :binary.copy(<<0>>, header.ram_size)
       }}
    end
  end

  @doc "Alias for `load/2`, useful at media-parsing call sites."
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(rom, opts \\ []), do: load(rom, opts)

  @doc "Reads a byte from a cartridge-owned address, or `$FF` when unmapped."
  @spec read(t(), 0..0xFFFF) :: byte()
  def read(%__MODULE__{rom: rom}, address) when address in 0x0000..0x7FFF,
    do: :binary.at(rom, address)

  def read(%__MODULE__{ram: <<>>}, address) when address in 0xA000..0xBFFF, do: 0xFF

  def read(%__MODULE__{ram: ram}, address) when address in 0xA000..0xBFFF,
    do: :binary.at(ram, rem(address - 0xA000, byte_size(ram)))

  def read(%__MODULE__{}, address) when address in 0x0000..0xFFFF, do: 0xFF

  @doc "Writes a byte to external RAM; writes elsewhere have no effect."
  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{ram: <<>>} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  def write(%__MODULE__{ram: ram} = cartridge, address, value)
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    offset = rem(address - 0xA000, byte_size(ram))
    <<prefix::binary-size(^offset), _old, suffix::binary>> = ram
    %{cartridge | ram: prefix <> <<value>> <> suffix}
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  defp validate_rom_length(%Header{rom_size: size}, rom) when byte_size(rom) == size, do: :ok

  defp validate_rom_length(%Header{rom_size: expected}, rom),
    do: {:error, {:rom_size_mismatch, expected, byte_size(rom)}}

  defp validate_mapper(%Header{mapper: :rom_only}), do: :ok
  defp validate_mapper(%Header{mapper: mapper}), do: {:error, {:unsupported_mapper, mapper}}

  defp validate_rom_only_size(%Header{rom_banks: 2}), do: :ok

  defp validate_rom_only_size(%Header{rom_banks: banks}),
    do: {:error, {:unsupported_rom_only_bank_count, banks}}

  defp validate_ram_declaration(%Header{features: features, ram_size: ram_size}) do
    has_ram? = :ram in features

    cond do
      has_ram? and ram_size == 0 ->
        {:error, :missing_ram_size}

      not has_ram? and ram_size != 0 ->
        {:error, {:unexpected_ram_size, ram_size}}

      has_ram? and ram_size > 0x2000 ->
        {:error, {:unsupported_rom_only_ram_size, ram_size}}

      true ->
        :ok
    end
  end
end
