defmodule Beamicom.NES.Cart do
  @moduledoc """
  Parsed cartridge: 16-byte iNES header + PRG/CHR data (spec §5.3).

  Extracts mapper number (both nibbles), mirroring (incl. four-screen),
  battery flag, and slices PRG-ROM / CHR-ROM, skipping a 512-byte trainer
  when flag 6 bit 2 is set.

  ## Sources
    * NESdev Wiki — iNES header format: https://www.nesdev.org/wiki/INES
    * NESdev Wiki — NES 2.0 (detected via flag 7 bits 2-3; extended fields
      deferred until a mapper needs them): https://www.nesdev.org/wiki/NES_2.0
  """

  import Bitwise

  defstruct [:mapper, :mirroring, :battery, :prg_rom, :chr_rom]

  def parse(<<"NES", 0x1A, prg, chr, flags6, flags7, _rest::binary>> = bin) do
    skip = 16 + if (flags6 &&& 0x04) != 0, do: 512, else: 0
    prg_size = prg * 0x4000
    chr_size = chr * 0x2000

    <<_::binary-size(^skip), prg_rom::binary-size(^prg_size), chr_rom::binary-size(^chr_size),
      _::binary>> = bin

    {:ok,
     %__MODULE__{
       mapper: (flags7 &&& 0xF0) + ((flags6 &&& 0xF0) >>> 4),
       mirroring: mirroring(flags6),
       battery: (flags6 &&& 0x02) != 0,
       prg_rom: prg_rom,
       chr_rom: chr_rom
     }}
  end

  def parse(_), do: {:error, :invalid_ines}

  defp mirroring(flags6) when (flags6 &&& 0x08) != 0, do: :four
  defp mirroring(flags6) when (flags6 &&& 0x01) != 0, do: :vertical
  defp mirroring(_), do: :horizontal
end
