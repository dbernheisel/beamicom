defmodule Beamicom.GBA.TestROM do
  @moduledoc false

  import Bitwise

  def build(program \\ <<0xFE, 0xFF, 0xFF, 0xEA>>, opts \\ []) when is_binary(program) do
    size = Keyword.get(opts, :size, 1024 * 1024)

    :binary.copy(<<0xFF>>, size)
    |> put_bytes(0, program)
    |> put_bytes(0xA0, padded(Keyword.get(opts, :title, "BEAMICOM GBA"), 12))
    |> put_bytes(0xAC, padded(Keyword.get(opts, :game_code, "BGAT"), 4))
    |> put_bytes(0xB0, padded(Keyword.get(opts, :maker_code, "01"), 2))
    |> put_byte(0xB2, 0x96)
    |> put_byte(0xB3, 0)
    |> put_byte(0xB4, 0)
    |> put_byte(0xBC, Keyword.get(opts, :software_version, 0))
    |> with_checksum()
  end

  def put_word(rom, offset, value),
    do: put_bytes(rom, offset, <<value::little-32>>)

  def put_halfword(rom, offset, value),
    do: put_bytes(rom, offset, <<value::little-16>>)

  def put_byte(rom, offset, value), do: put_bytes(rom, offset, <<value>>)

  def with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0xA0, 0x1D)
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> then(&(-(&1 + 0x19) &&& 0xFF))

    put_byte(rom, 0xBD, checksum)
  end

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end

  defp padded(value, size) do
    value = IO.iodata_to_binary(value)
    binary_part(value <> :binary.copy(<<0>>, size), 0, size)
  end
end
