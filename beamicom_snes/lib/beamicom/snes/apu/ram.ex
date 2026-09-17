defmodule Beamicom.SNES.APU.RAM do
  @moduledoc false

  alias Beamicom.SNES.APU.RAM.Overlay

  @size 0x10000

  @compile {:inline, get: 2, put: 3}

  def new, do: new(:atomics)

  def new(:array), do: :array.new(@size, default: 0, fixed: true)
  def new(:atomics), do: :atomics.new(@size, signed: false)

  def overlay(memory), do: %Overlay{base: memory}

  def get(%Overlay{base: base, writes: writes}, address) do
    address = Bitwise.band(address, 0xFFFF)

    case Map.fetch(writes, address) do
      {:ok, value} -> value
      :error -> get(base, address)
    end
  end

  def get(memory, address) when is_reference(memory),
    do: :atomics.get(memory, Bitwise.band(address, 0xFFFF) + 1)

  def get(memory, address), do: :array.get(Bitwise.band(address, 0xFFFF), memory)

  def put(%Overlay{} = memory, address, value) do
    address = Bitwise.band(address, 0xFFFF)
    value = Bitwise.band(value, 0xFF)
    %{memory | writes: Map.put(memory.writes, address, value)}
  end

  def put(memory, address, value) when is_reference(memory) do
    :ok = :atomics.put(memory, Bitwise.band(address, 0xFFFF) + 1, Bitwise.band(value, 0xFF))
    memory
  end

  def put(memory, address, value),
    do: :array.set(Bitwise.band(address, 0xFFFF), Bitwise.band(value, 0xFF), memory)

  def backend(memory) when is_reference(memory), do: :atomics
  def backend(_memory), do: :array

  def mutable?(memory), do: is_reference(memory)

  def valid?(memory) when is_reference(memory) do
    :atomics.info(memory).size == @size
  rescue
    ArgumentError -> false
  end

  def valid?(_memory), do: false

  def clone(memory) when is_reference(memory), do: memory |> to_binary() |> from_binary(:atomics)
  def clone(memory), do: memory

  def to_binary(memory) when is_reference(memory) do
    for index <- 1..@size, into: <<>>, do: <<:atomics.get(memory, index)>>
  end

  def to_binary(memory), do: memory |> :array.to_list() |> :erlang.list_to_binary()

  def from_binary(binary, :array) when byte_size(binary) == @size do
    binary
    |> :binary.bin_to_list()
    |> :array.from_list(0)
    |> :array.fix()
  end

  def from_binary(binary, :atomics) when byte_size(binary) == @size do
    memory = :atomics.new(@size, signed: false)

    for <<value <- binary>>, reduce: 1 do
      index ->
        :ok = :atomics.put(memory, index, value)
        index + 1
    end

    memory
  end

  def from_binary(binary) when byte_size(binary) == @size, do: from_binary(binary, :atomics)
end
