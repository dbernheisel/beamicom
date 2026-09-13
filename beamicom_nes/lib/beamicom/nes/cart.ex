defmodule Beamicom.NES.Cart do
  @moduledoc """
  Parsed cartridge: 16-byte iNES header + PRG/CHR data (spec §5.3).

  Extracts mapper number (both nibbles), mirroring (incl. four-screen),
  battery flag, and slices PRG-ROM / CHR-ROM, skipping a 512-byte trainer
  when flag 6 bit 2 is set.

  ## Sources
    * NESdev Wiki — iNES header format: https://www.nesdev.org/wiki/INES
    * NESdev Wiki — NES 2.0 mapper/submapper, ROM-size, and RAM-size fields:
      https://www.nesdev.org/wiki/NES_2.0
  """

  import Bitwise

  defstruct [
    :mapper,
    :submapper,
    :mirroring,
    :battery,
    :prg_rom,
    :chr_rom,
    :prg_ram_size,
    :prg_nvram_size,
    :chr_ram_size,
    :chr_nvram_size,
    nes2?: false
  ]

  def parse(
        <<"NES", 0x1A, prg, chr, flags6, flags7, byte8, byte9, byte10, byte11, _::binary-size(4),
          _rest::binary>> = bin
      ) do
    nes2? = (flags7 &&& 0x0C) == 0x08
    skip = 16 + if (flags6 &&& 0x04) != 0, do: 512, else: 0
    prg_size = rom_size(prg, if(nes2?, do: byte9 &&& 0x0F, else: 0), 0x4000)
    chr_size = rom_size(chr, if(nes2?, do: byte9 >>> 4, else: 0), 0x2000)

    {prg_ram_size, prg_nvram_size, chr_ram_size, chr_nvram_size} =
      if nes2? do
        {ram_size(byte10 &&& 0x0F), ram_size(byte10 >>> 4), ram_size(byte11 &&& 0x0F),
         ram_size(byte11 >>> 4)}
      else
        # In iNES 1.0 byte 8 is an 8KB PRG-RAM unit count; zero conventionally
        # means one unit. CHR-less carts conventionally provide 8KB CHR RAM.
        {max(byte8, 1) * 0x2000, 0, if(chr == 0, do: 0x2000, else: 0), 0}
      end

    <<_::binary-size(^skip), prg_rom::binary-size(^prg_size), chr_rom::binary-size(^chr_size),
      _::binary>> = bin

    {:ok,
     %__MODULE__{
       mapper:
         (flags7 &&& 0xF0) + ((flags6 &&& 0xF0) >>> 4) +
           if(nes2?, do: (byte8 &&& 0x0F) <<< 8, else: 0),
       submapper: if(nes2?, do: byte8 >>> 4, else: 0),
       mirroring: mirroring(flags6),
       battery: (flags6 &&& 0x02) != 0,
       prg_rom: prg_rom,
       chr_rom: chr_rom,
       prg_ram_size: prg_ram_size,
       prg_nvram_size: prg_nvram_size,
       chr_ram_size: chr_ram_size,
       chr_nvram_size: chr_nvram_size,
       nes2?: nes2?
     }}
  end

  def parse(_), do: {:error, :invalid_ines}

  defp mirroring(flags6) when (flags6 &&& 0x08) != 0, do: :four
  defp mirroring(flags6) when (flags6 &&& 0x01) != 0, do: :vertical
  defp mirroring(_), do: :horizontal

  defp rom_size(lsb, 0x0F, _unit) do
    exponent = lsb >>> 2
    multiplier = (lsb &&& 0x03) * 2 + 1
    (1 <<< exponent) * multiplier
  end

  defp rom_size(lsb, msb, unit), do: (msb <<< 8 ||| lsb) * unit
  defp ram_size(0), do: 0
  defp ram_size(shift), do: 64 <<< shift
end
