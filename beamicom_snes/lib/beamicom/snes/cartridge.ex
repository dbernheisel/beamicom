defmodule Beamicom.SNES.Cartridge do
  @moduledoc """
  Loads headered or headerless LoROM, HiROM, and ExHiROM cartridge images.

  ROM reads use the same recursive mirroring shape used by SNES checksum
  tooling. This matters for valid non-power-of-two images: the tail chip of a
  3 MiB cartridge mirrors into the final MiB of its 4 MiB decode space rather
  than wrapping the entire image with a simple modulo.
  """

  import Bitwise
  alias Beamicom.SNES.Header

  @candidates [lorom: 0x007FC0, hirom: 0x00FFC0, exhirom: 0x40FFC0]

  @enforce_keys [
    :rom,
    :size,
    :layout,
    :header,
    :copier_header?,
    :checksum,
    :checksum_valid?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec load(binary()) :: {:ok, t()} | {:error, term()}
  def load(media) when is_binary(media) do
    preferred_headered? = rem(byte_size(media), 1024) == 512

    variants =
      if byte_size(media) >= 512 do
        headerless = {false, media, not preferred_headered?}
        stripped = {true, binary_part(media, 512, byte_size(media) - 512), preferred_headered?}
        if preferred_headered?, do: [stripped, headerless], else: [headerless, stripped]
      else
        [{false, media, true}]
      end

    variants
    |> Enum.flat_map(&candidates/1)
    |> Enum.filter(fn {_score, _priority, header, _headered?, _rom} ->
      Header.layout_matches?(header)
    end)
    |> Enum.max_by(
      fn {score, priority, _header, _headered?, _rom} -> {score, priority} end,
      fn -> nil end
    )
    |> finish_load()
  end

  def load(_media), do: {:error, :invalid_rom}

  @doc "Maps a 24-bit CPU address to a mirrored physical ROM offset."
  @spec address_to_offset(t(), non_neg_integer()) :: {:ok, non_neg_integer()} | :unmapped
  def address_to_offset(%__MODULE__{} = cart, address)
      when is_integer(address) and address in 0..0xFFFFFF do
    case raw_offset(cart.layout, address) do
      :unmapped -> :unmapped
      offset when offset < cart.size -> {:ok, offset}
      offset -> {:ok, mirror_offset(offset, cart.size)}
    end
  end

  def address_to_offset(%__MODULE__{}, _address), do: :unmapped

  @doc "Reads one byte from a mapped CPU address."
  @spec read(t(), non_neg_integer()) :: {:ok, byte()} | :unmapped
  def read(%__MODULE__{} = cart, address) do
    with {:ok, offset} <- address_to_offset(cart, address) do
      {:ok, :binary.at(cart.rom, offset)}
    end
  end

  @doc false
  def read_or(%__MODULE__{} = cart, address, default)
      when is_integer(address) and address in 0..0xFFFFFF do
    case raw_offset(cart.layout, address) do
      :unmapped -> default
      offset when offset < cart.size -> :binary.at(cart.rom, offset)
      offset -> :binary.at(cart.rom, mirror_offset(offset, cart.size))
    end
  end

  def read_or(%__MODULE__{}, _address, default), do: default

  @doc "Maps a CPU address to battery-backed cartridge RAM when present."
  @spec address_to_sram_offset(t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :unmapped
  def address_to_sram_offset(%__MODULE__{header: %{declared_ram_size: size}}, _address)
      when not is_integer(size) or size <= 0,
      do: :unmapped

  def address_to_sram_offset(%__MODULE__{} = cart, address)
      when is_integer(address) and address in 0..0xFFFFFF do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    raw =
      case cart.layout do
        :lorom when offset < 0x8000 and (bank in 0x70..0x7D or bank in 0xF0..0xFF) ->
          (bank &&& 0x0F) <<< 15 ||| offset

        layout
        when layout in [:hirom, :exhirom] and offset in 0x6000..0x7FFF and
               (bank in 0x20..0x3F or bank in 0xA0..0xBF) ->
          (bank &&& 0x1F) <<< 13 ||| (offset &&& 0x1FFF)

        _other ->
          :unmapped
      end

    if raw == :unmapped,
      do: :unmapped,
      else: {:ok, rem(raw, cart.header.declared_ram_size)}
  end

  def address_to_sram_offset(%__MODULE__{}, _address), do: :unmapped

  @doc "Mirrors an offset into a possibly non-power-of-two physical ROM size."
  @spec mirror_offset(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def mirror_offset(offset, size)
      when is_integer(offset) and offset >= 0 and is_integer(size) and size > 0 do
    do_mirror(offset, size, highest_power_of_two(max(offset, size)), 0)
  end

  @doc "16-bit checksum after recursively mirroring the tail to the next power of two."
  @spec checksum(binary()) :: non_neg_integer()
  def checksum(rom) when is_binary(rom) and byte_size(rom) > 0 do
    rom |> mirrored_checksum() |> band(0xFFFF)
  end

  defp candidates({headered?, rom, preferred?}) do
    priority = if preferred?, do: 1, else: 0

    for {layout, offset} <- @candidates,
        {:ok, header} <- [Header.parse(rom, layout, offset)] do
      {Header.score(header), priority, header, headered?, rom}
    end
  end

  defp finish_load(nil), do: {:error, :snes_header_not_found}

  defp finish_load({score, _priority, header, headered?, rom}) when score >= 12 do
    checksum = checksum(rom)

    {:ok,
     %__MODULE__{
       rom: rom,
       size: byte_size(rom),
       layout: header.layout,
       header: header,
       copier_header?: headered?,
       checksum: checksum,
       checksum_valid?: checksum == header.checksum
     }}
  end

  defp finish_load(_candidate), do: {:error, :snes_header_not_found}

  defp raw_offset(:lorom, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    full_rom_bank? = bank in 0x40..0x6F or bank in 0xC0..0xEF

    if bank not in [0x7E, 0x7F] and (offset >= 0x8000 or full_rom_bank?) do
      (bank &&& 0x7F) <<< 15 ||| (offset &&& 0x7FFF)
    else
      :unmapped
    end
  end

  defp raw_offset(:hirom, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    if bank not in [0x7E, 0x7F] and (offset >= 0x8000 or bank in 0x40..0x7D or bank >= 0xC0) do
      (bank &&& 0x3F) <<< 16 ||| offset
    else
      :unmapped
    end
  end

  defp raw_offset(:exhirom, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      bank >= 0xC0 -> (bank - 0xC0) <<< 16 ||| offset
      bank in 0x40..0x7D -> bank <<< 16 ||| offset
      bank in 0x00..0x3F and offset >= 0x8000 -> 0x400000 ||| bank <<< 16 ||| offset
      bank in 0x80..0xBF and offset >= 0x8000 -> (bank &&& 0x3F) <<< 16 ||| offset
      true -> :unmapped
    end
  end

  defp do_mirror(offset, size, _mask, base) when offset < size, do: base + offset

  defp do_mirror(offset, size, mask, base) do
    mask = lower_mask_to_set_bit(mask, offset)
    offset = offset - mask

    if size > mask do
      do_mirror(offset, size - mask, mask >>> 1, base + mask)
    else
      do_mirror(offset, size, mask >>> 1, base)
    end
  end

  defp lower_mask_to_set_bit(mask, offset) when (offset &&& mask) == 0,
    do: lower_mask_to_set_bit(mask >>> 1, offset)

  defp lower_mask_to_set_bit(mask, _offset), do: mask

  # Sum physical pieces and weight a recursively mirrored tail instead of
  # expanding a multi-megabyte virtual ROM byte by byte.
  defp mirrored_checksum(binary) do
    size = byte_size(binary)
    base_size = highest_power_of_two(size)

    if size == base_size do
      byte_sum(binary)
    else
      tail_size = size - base_size
      tail_span = next_power_of_two(tail_size)
      prefix = binary_part(binary, 0, base_size)
      tail = binary_part(binary, base_size, tail_size)
      byte_sum(prefix) + mirrored_checksum(tail) * div(base_size, tail_span)
    end
  end

  defp byte_sum(binary) do
    for <<byte <- binary>>, reduce: 0 do
      sum -> sum + byte
    end
  end

  defp next_power_of_two(value), do: next_power_of_two(value, 1)
  defp next_power_of_two(value, power) when power >= value, do: power
  defp next_power_of_two(value, power), do: next_power_of_two(value, power <<< 1)

  defp highest_power_of_two(value), do: highest_power_of_two(value, 1)
  defp highest_power_of_two(value, power) when power <<< 1 > value, do: power
  defp highest_power_of_two(value, power), do: highest_power_of_two(value, power <<< 1)
end
