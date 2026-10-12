defmodule Beamicom.GBA.DiagnosticROM do
  @moduledoc "Builds a valid open diagnostic cartridge that loops in ARM state."

  import Bitwise

  @doc "Returns a 1 MiB cartridge image containing `B .` at its entry point."
  def loop do
    :binary.copy(<<0xFF>>, 1024 * 1024)
    |> put_bytes(0, <<0xEAFF_FFFE::little-32>>)
    |> put_bytes(0xA0, "BEAMICOM GBA")
    |> put_bytes(0xAC, "BGAT")
    |> put_bytes(0xB0, "01")
    |> put_byte(0xB2, 0x96)
    |> put_byte(0xB3, 0)
    |> put_byte(0xB4, 0)
    |> put_byte(0xBC, 0)
    |> with_checksum()
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0xA0, 0x1D)
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> then(&(-(&1 + 0x19) &&& 0xFF))

    put_byte(rom, 0xBD, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
