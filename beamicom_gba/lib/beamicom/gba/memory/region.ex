defmodule Beamicom.GBA.Memory.Region do
  @moduledoc """
  Page-chunked byte memory with value semantics.

  Writes copy one small page and the page tuple rather than the complete
  emulated region. The page size is configurable so benchmarks can select an
  appropriate trade-off without changing callers.
  """

  import Bitwise

  @default_page_size 1024

  @compile {:inline, wrap: 2}

  @enforce_keys [:size, :page_size, :page_shift, :page_mask, :wrap_mask, :pages]
  defstruct @enforce_keys

  @doc "Allocates a zero-filled region."
  def new(size, opts \\ []) when is_integer(size) and size > 0 and is_list(opts) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    if not is_integer(page_size) or not power_of_two?(page_size) or rem(size, page_size) != 0 do
      raise ArgumentError, "region size must be an exact multiple of a power-of-two page size"
    end

    page = :binary.copy(<<0>>, page_size)
    pages = List.duplicate(page, div(size, page_size)) |> List.to_tuple()
    build(size, page_size, pages)
  end

  @doc "Builds a region from an exact-size binary."
  def from_binary(binary, opts \\ []) when is_binary(binary) and is_list(opts) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    if byte_size(binary) == 0 or not power_of_two?(page_size) or
         rem(byte_size(binary), page_size) != 0 do
      raise ArgumentError, "binary size must be an exact multiple of a power-of-two page size"
    end

    pages = for <<page::binary-size(^page_size) <- binary>>, do: page
    build(byte_size(binary), page_size, List.to_tuple(pages))
  end

  @doc "Returns a byte at a wrapped offset."
  def read(%__MODULE__{} = region, offset) when is_integer(offset) do
    offset = wrap(region, offset)
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask
    region.pages |> elem(page_index) |> :binary.at(page_offset)
  end

  @doc "Returns a little-endian halfword at a wrapped offset."
  def read16(%__MODULE__{} = region, offset) when is_integer(offset) do
    offset = wrap(region, offset)
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask

    if page_offset + 2 <= region.page_size do
      page = elem(region.pages, page_index)
      <<_::binary-size(^page_offset), value::little-16, _::binary>> = page
      value
    else
      read_unsigned(region, offset, 2)
    end
  end

  @doc "Returns a little-endian word at a wrapped offset."
  def read32(%__MODULE__{} = region, offset) when is_integer(offset) do
    offset = wrap(region, offset)
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask

    if page_offset + 4 <= region.page_size do
      page = elem(region.pages, page_index)
      <<_::binary-size(^page_offset), value::little-32, _::binary>> = page
      value
    else
      read_unsigned(region, offset, 4)
    end
  end

  @doc "Writes a byte at a wrapped offset."
  def write(%__MODULE__{} = region, offset, value)
      when is_integer(offset) and value in 0x00..0xFF do
    offset = wrap(region, offset)
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask
    page = elem(region.pages, page_index)

    updated =
      binary_part(page, 0, page_offset) <>
        <<value>> <> binary_part(page, page_offset + 1, region.page_size - page_offset - 1)

    %{region | pages: put_elem(region.pages, page_index, updated)}
  end

  @doc "Writes a little-endian halfword at a wrapped offset."
  def write16(%__MODULE__{} = region, offset, value)
      when is_integer(offset) and value in 0x0000..0xFFFF do
    write_binary(region, offset, <<value::little-16>>)
  end

  @doc "Writes a little-endian word at a wrapped offset."
  def write32(%__MODULE__{} = region, offset, value)
      when is_integer(offset) and value in 0x0000_0000..0xFFFF_FFFF do
    write_binary(region, offset, <<value::little-32>>)
  end

  @doc "Reads a packed binary from a wrapped offset."
  def read_binary(%__MODULE__{} = region, offset, length)
      when is_integer(offset) and is_integer(length) and length >= 0 do
    region
    |> read_binary(wrap(region, offset), length, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc "Writes a packed binary at a wrapped offset, copying each affected page once."
  def write_binary(%__MODULE__{} = region, offset, binary)
      when is_integer(offset) and is_binary(binary) do
    do_write_binary(region, wrap(region, offset), binary)
  end

  @doc "Returns the region as one packed binary."
  def to_binary(%__MODULE__{pages: pages}) do
    pages |> Tuple.to_list() |> IO.iodata_to_binary()
  end

  @doc false
  def page_signature(%__MODULE__{} = region, offset, length)
      when is_integer(offset) and is_integer(length) and length > 0 do
    offset = wrap(region, offset)
    first = offset >>> region.page_shift
    last = wrap(region, offset + length - 1) >>> region.page_shift

    if first == last,
      do: elem(region.pages, first),
      else: {elem(region.pages, first), elem(region.pages, last)}
  end

  defp build(size, page_size, pages) do
    %__MODULE__{
      size: size,
      page_size: page_size,
      page_shift: page_shift(page_size, 0),
      page_mask: page_size - 1,
      wrap_mask: if(power_of_two?(size), do: size - 1),
      pages: pages
    }
  end

  defp read_unsigned(region, offset, width) do
    offset = wrap(region, offset)
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask

    if page_offset + width <= region.page_size do
      region.pages
      |> elem(page_index)
      |> binary_part(page_offset, width)
      |> :binary.decode_unsigned(:little)
    else
      region
      |> read_binary(offset, width, [])
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> :binary.decode_unsigned(:little)
    end
  end

  defp wrap(%__MODULE__{wrap_mask: nil, size: size}, offset), do: Integer.mod(offset, size)
  defp wrap(%__MODULE__{wrap_mask: mask}, offset), do: offset &&& mask

  defp power_of_two?(value) when is_integer(value) and value > 0,
    do: (value &&& value - 1) == 0

  defp power_of_two?(_value), do: false

  defp page_shift(1, shift), do: shift
  defp page_shift(size, shift), do: page_shift(size >>> 1, shift + 1)

  defp read_binary(_region, _offset, 0, chunks), do: chunks

  defp read_binary(region, offset, length, chunks) do
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask
    take = min(length, region.page_size - page_offset)
    chunk = region.pages |> elem(page_index) |> binary_part(page_offset, take)
    next_offset = rem(offset + take, region.size)
    read_binary(region, next_offset, length - take, [chunk | chunks])
  end

  defp do_write_binary(region, _offset, <<>>), do: region

  defp do_write_binary(region, offset, binary) do
    page_index = offset >>> region.page_shift
    page_offset = offset &&& region.page_mask
    take = min(byte_size(binary), region.page_size - page_offset)
    <<chunk::binary-size(^take), rest::binary>> = binary
    page = elem(region.pages, page_index)

    updated =
      binary_part(page, 0, page_offset) <>
        chunk <> binary_part(page, page_offset + take, region.page_size - page_offset - take)

    region = %{region | pages: put_elem(region.pages, page_index, updated)}
    do_write_binary(region, rem(offset + take, region.size), rest)
  end
end
