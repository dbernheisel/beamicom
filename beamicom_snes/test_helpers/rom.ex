defmodule Beamicom.SNESTestROM do
  import Bitwise

  alias Beamicom.SNES.Cartridge

  @offsets %{lorom: 0x7FC0, hirom: 0xFFC0, exhirom: 0x40FFC0}
  @modes %{lorom: 0x20, hirom: 0x21, exhirom: 0x25}
  @sizes %{lorom: 0x10000, hirom: 0x10000, exhirom: 0x500000}

  def build(layout, opts \\ []) do
    size = Keyword.get(opts, :size, Map.fetch!(@sizes, layout))
    reset = Keyword.get(opts, :reset, 0x8000)
    title = Keyword.get(opts, :title, "BEAMICOM SNES TEST")
    mode = Keyword.get(opts, :map_mode, Map.fetch!(@modes, layout))
    destination = Keyword.get(opts, :destination, 1)
    ram_size_code = Keyword.get(opts, :ram_size_code, 0)
    program = Keyword.get(opts, :program, <<0xEA>>)
    header_offset = Map.fetch!(@offsets, layout)
    padded_title = binary_part(title <> :binary.copy(<<0x20>>, 21), 0, 21)

    rom =
      :binary.copy(<<0>>, size)
      |> put_bytes(header_offset, padded_title)
      |> put_byte(header_offset + 0x15, mode)
      |> put_byte(header_offset + 0x16, 0)
      |> put_byte(header_offset + 0x17, rom_size_code(size))
      |> put_byte(header_offset + 0x18, ram_size_code)
      |> put_byte(header_offset + 0x19, destination)
      |> put_byte(header_offset + 0x1A, 0x33)
      |> put_byte(header_offset + 0x1B, 0)
      |> put_bytes(header_offset + 0x3C, <<reset &&& 0xFF, reset >>> 8>>)
      |> put_bytes(program_offset(layout, reset), program)

    checksum = Cartridge.checksum(rom) + 510 &&& 0xFFFF
    complement = bxor(checksum, 0xFFFF)

    rom =
      rom
      |> put_bytes(header_offset + 0x1C, <<complement &&& 0xFF, complement >>> 8>>)
      |> put_bytes(header_offset + 0x1E, <<checksum &&& 0xFF, checksum >>> 8>>)

    if Keyword.get(opts, :headered, false), do: :binary.copy(<<0xAA>>, 512) <> rom, else: rom
  end

  def put_byte(binary, offset, byte), do: put_bytes(binary, offset, <<byte>>)

  def put_bytes(binary, offset, bytes) do
    suffix_offset = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
  end

  defp program_offset(:lorom, reset), do: reset &&& 0x7FFF
  defp program_offset(:hirom, reset), do: reset
  defp program_offset(:exhirom, reset), do: 0x400000 + reset

  defp rom_size_code(size), do: trunc(:math.log2(size / 1024))
end
