defmodule Beamicom.GB.Cartridge.RAM do
  @moduledoc false

  import Bitwise

  @page_shift 8
  @page_size 1 <<< @page_shift
  @page_mask @page_size - 1

  @enforce_keys [:pages, :size]
  defstruct @enforce_keys

  @type t :: %__MODULE__{pages: tuple(), size: non_neg_integer()}

  @compile {:inline, read: 2, read_window: 3, size: 1, empty?: 1}

  @spec new(binary()) :: t()
  def new(binary) when is_binary(binary) and rem(byte_size(binary), @page_size) == 0 do
    pages =
      for <<page::binary-size(@page_size) <- binary>>, into: [], do: :binary.copy(page)

    %__MODULE__{pages: List.to_tuple(pages), size: byte_size(binary)}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @spec read(t(), non_neg_integer()) :: byte()
  def read(%__MODULE__{pages: pages}, offset) do
    page = elem(pages, offset >>> @page_shift)
    :binary.at(page, offset &&& @page_mask)
  end

  @spec read_window(t(), non_neg_integer(), 0..0x1FFF) :: byte()
  def read_window(%__MODULE__{pages: pages}, page_offset, window_offset) do
    page = elem(pages, page_offset + (window_offset >>> @page_shift))
    :binary.at(page, window_offset &&& @page_mask)
  end

  @spec put(t(), non_neg_integer(), byte()) :: :unchanged | {:changed, t()}
  def put(%__MODULE__{pages: pages} = ram, offset, value) when value in 0x00..0xFF do
    page_index = offset >>> @page_shift
    byte_index = offset &&& @page_mask
    page = elem(pages, page_index)

    if :binary.at(page, byte_index) == value do
      :unchanged
    else
      <<prefix::binary-size(^byte_index), _old, suffix::binary>> = page
      {:changed, %{ram | pages: put_elem(pages, page_index, prefix <> <<value>> <> suffix)}}
    end
  end

  @spec put_window(t(), non_neg_integer(), 0..0x1FFF, byte()) :: :unchanged | {:changed, t()}
  def put_window(%__MODULE__{} = ram, page_offset, window_offset, value),
    do: put(ram, (page_offset <<< @page_shift) + window_offset, value)

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{pages: pages}),
    do: pages |> Tuple.to_list() |> IO.iodata_to_binary()
end
