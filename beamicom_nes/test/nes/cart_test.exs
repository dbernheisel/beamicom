defmodule Beamicom.NES.CartTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.Cart

  # 16-byte iNES header + PRG banks (16KB each) + CHR banks (8KB each)
  defp rom(opts) do
    prg = Keyword.get(opts, :prg, 1)
    chr = Keyword.get(opts, :chr, 1)
    flags6 = Keyword.get(opts, :flags6, 0)
    flags7 = Keyword.get(opts, :flags7, 0)
    byte8 = Keyword.get(opts, :byte8, 0)
    byte9 = Keyword.get(opts, :byte9, 0)
    byte10 = Keyword.get(opts, :byte10, 0)
    byte11 = Keyword.get(opts, :byte11, 0)
    trainer = Keyword.get(opts, :trainer, <<>>)
    prg_data = Keyword.get(opts, :prg_data, :binary.copy(<<0xAA>>, prg * 0x4000))
    chr_data = Keyword.get(opts, :chr_data, :binary.copy(<<0xBB>>, chr * 0x2000))

    <<"NES", 0x1A, prg, chr, flags6, flags7, byte8, byte9, byte10, byte11, 0, 0, 0, 0>> <>
      trainer <> prg_data <> chr_data
  end

  test "parses a minimal NROM cartridge" do
    assert {:ok, cart} = Cart.parse(rom(prg: 1, chr: 1))
    assert %Cart{mapper: 0, mirroring: :horizontal, battery: false} = cart
    assert byte_size(cart.prg_rom) == 0x4000
    assert byte_size(cart.chr_rom) == 0x2000
  end

  test "assembles the mapper number from both nibbles" do
    # low nibble in flags6 high bits, high nibble in flags7 high bits: 0x2 | (0x3 << 4) = 0x32
    assert {:ok, %Cart{mapper: 0x32}} = Cart.parse(rom(flags6: 0x20, flags7: 0x30))
  end

  test "parses NES 2.0 mapper extension, submapper, and RAM sizes" do
    assert {:ok, cart} =
             Cart.parse(
               rom(
                 flags6: 0x50,
                 flags7: 0x08,
                 byte8: 0x21,
                 byte10: 0x87,
                 byte11: 0x07
               )
             )

    assert cart.nes2?
    assert cart.mapper == 0x105
    assert cart.submapper == 2
    assert cart.prg_ram_size == 0x2000
    assert cart.prg_nvram_size == 0x4000
    assert cart.chr_ram_size == 0x2000
    assert cart.chr_nvram_size == 0
  end

  test "reads vertical mirroring and battery flags" do
    assert {:ok, %Cart{mirroring: :vertical, battery: true}} =
             Cart.parse(rom(flags6: 0x03))
  end

  test "four-screen bit overrides mirroring direction" do
    assert {:ok, %Cart{mirroring: :four}} = Cart.parse(rom(flags6: 0x08))
    assert {:ok, %Cart{mirroring: :four}} = Cart.parse(rom(flags6: 0x09))
  end

  test "skips a 512-byte trainer before PRG when present" do
    prg = :binary.copy(<<0x11>>, 0x4000)

    assert {:ok, %Cart{prg_rom: ^prg}} =
             Cart.parse(rom(flags6: 0x04, trainer: :binary.copy(<<0xFF>>, 512), prg_data: prg))
  end

  test "rejects a file without the iNES magic" do
    assert {:error, :invalid_ines} = Cart.parse(<<"XXXX", 0::size(96)>>)
  end
end
