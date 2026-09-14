defmodule Beamicom.SNES.CartridgeTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.Cartridge
  alias Beamicom.SNESTestROM

  test "selects LoROM, HiROM, and ExHiROM internal headers" do
    for layout <- [:lorom, :hirom, :exhirom] do
      assert {:ok, cartridge} = layout |> SNESTestROM.build() |> Cartridge.load()
      assert cartridge.layout == layout
      assert cartridge.header.layout == layout
      assert cartridge.header.title == "BEAMICOM SNES TEST"
      assert cartridge.header.reset_vector == 0x8000
      assert cartridge.header.region == :ntsc
      refute cartridge.copier_header?
    end
  end

  test "strips a 512-byte copier header before selecting the internal header" do
    media = SNESTestROM.build(:lorom, headered: true)

    assert rem(byte_size(media), 1024) == 512
    assert {:ok, cartridge} = Cartridge.load(media)
    assert cartridge.copier_header?
    assert cartridge.size == byte_size(media) - 512
    assert cartridge.checksum_valid?
  end

  test "falls back to the 512-byte header offset when file-size detection is inconclusive" do
    media = SNESTestROM.build(:lorom, headered: true) <> <<0>>

    assert rem(byte_size(media), 1024) != 512
    assert {:ok, cartridge} = Cartridge.load(media)
    assert cartridge.copier_header?
    assert cartridge.header.title == "BEAMICOM SNES TEST"
  end

  test "maps each supported cartridge layout into the CPU address space" do
    lorom = load!(:lorom)
    hirom = load!(:hirom)
    exhirom = load!(:exhirom)

    assert Cartridge.address_to_offset(lorom, 0x008000) == {:ok, 0x000000}
    assert Cartridge.address_to_offset(lorom, 0x018000) == {:ok, 0x008000}
    assert Cartridge.address_to_offset(lorom, 0x808000) == {:ok, 0x000000}
    assert Cartridge.address_to_offset(lorom, 0x007FFF) == :unmapped

    large_lorom = load!(:lorom, size: 3 * 1024 * 1024)
    assert Cartridge.address_to_offset(large_lorom, 0xC00000) == {:ok, 0x200000}
    assert Cartridge.address_to_offset(large_lorom, 0x700000) == :unmapped

    assert Cartridge.address_to_offset(hirom, 0xC01234) == {:ok, 0x001234}
    assert Cartridge.address_to_offset(hirom, 0x008000) == {:ok, 0x008000}
    assert Cartridge.address_to_offset(hirom, 0x001234) == :unmapped

    assert Cartridge.address_to_offset(exhirom, 0xC00000) == {:ok, 0x000000}
    assert Cartridge.address_to_offset(exhirom, 0x400000) == {:ok, 0x400000}
    assert Cartridge.address_to_offset(exhirom, 0x008000) == {:ok, 0x408000}
    assert Cartridge.address_to_offset(exhirom, 0x808000) == {:ok, 0x008000}
  end

  test "recursively mirrors a non-power-of-two ROM tail" do
    size = 3 * 1024 * 1024

    assert Cartridge.mirror_offset(0x2FFFFF, size) == 0x2FFFFF
    assert Cartridge.mirror_offset(0x300000, size) == 0x200000
    assert Cartridge.mirror_offset(0x380000, size) == 0x280000
    assert Cartridge.mirror_offset(0x3FFFFF, size) == 0x2FFFFF
    assert Cartridge.checksum(<<1, 2, 3>>) == 9
    assert Cartridge.checksum(<<1, 2, 3, 4, 5>>) == 30
  end

  test "maps LoROM and HiROM battery-backed RAM mirrors" do
    lorom = load!(:lorom, ram_size_code: 3)
    hirom = load!(:hirom, ram_size_code: 3)

    assert Cartridge.address_to_sram_offset(lorom, 0x700000) == {:ok, 0}
    assert Cartridge.address_to_sram_offset(lorom, 0x702000) == {:ok, 0}
    assert Cartridge.address_to_sram_offset(lorom, 0xF00001) == {:ok, 1}
    assert Cartridge.address_to_sram_offset(lorom, 0x6F0000) == :unmapped

    assert Cartridge.address_to_sram_offset(hirom, 0x206000) == {:ok, 0}
    assert Cartridge.address_to_sram_offset(hirom, 0x216000) == {:ok, 0}
    assert Cartridge.address_to_sram_offset(hirom, 0xA06001) == {:ok, 1}
    assert Cartridge.address_to_sram_offset(hirom, 0x706000) == :unmapped
  end

  test "reports media without a plausible mapped internal header" do
    assert {:error, :snes_header_not_found} = Cartridge.load(:binary.copy(<<0>>, 0x10000))
    assert {:error, :snes_header_not_found} = Cartridge.load(<<1, 2, 3>>)
  end

  defp load!(layout, opts \\ []) do
    {:ok, cartridge} = layout |> SNESTestROM.build(opts) |> Cartridge.load()
    cartridge
  end
end
