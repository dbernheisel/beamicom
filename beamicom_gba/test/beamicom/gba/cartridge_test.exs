defmodule Beamicom.GBA.CartridgeTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Cartridge, TestROM}

  test "parses the GBA header and mirrors Game Pak ROM windows" do
    rom = TestROM.build(<<1, 2, 3, 4>>, title: "ELIXIR", game_code: "EXBA")

    assert {:ok, cartridge} = Cartridge.load(rom)
    assert cartridge.title == "ELIXIR"
    assert cartridge.game_code == "EXBA"
    assert cartridge.maker_code == "01"
    assert cartridge.unit_code == 0
    assert cartridge.software_version == 0
    assert Cartridge.backup_type(cartridge) == :none
    assert Cartridge.read(cartridge, 0x0800_0000) == 1
    assert Cartridge.read(cartridge, 0x0A00_0001) == 2
    assert Cartridge.read(cartridge, 0x0C00_0003) == 4
  end

  test "initializes detected backup data and accepts exact persisted bytes" do
    rom = TestROM.build("SRAM_V100")
    save_data = :binary.copy(<<0xA5>>, 32 * 1024)

    assert {:ok, cartridge} = Cartridge.load(rom, save_data: save_data)
    assert Cartridge.backup_type(cartridge) == :sram
    assert Cartridge.backup_data(cartridge) == save_data

    assert {:error, {:invalid_save_size, 32_768, 1}} =
             Cartridge.load(rom, save_data: <<0>>)
  end

  test "rejects malformed media at the cartridge boundary" do
    assert {:error, {:rom_too_small, 0xC0, 3}} = Cartridge.load(<<1, 2, 3>>)
    assert {:error, :invalid_media} = Cartridge.load(:not_binary)

    invalid_fixed = TestROM.build() |> TestROM.put_byte(0xB2, 0)
    assert {:error, {:invalid_fixed_value, 0}} = Cartridge.load(invalid_fixed)

    invalid_checksum = TestROM.build() |> TestROM.put_byte(0xBD, 0)

    assert {:error, {:header_checksum_mismatch, _expected, 0}} =
             Cartridge.load(invalid_checksum)

    assert {:ok, _cartridge} =
             Cartridge.load(invalid_checksum, validate_header_checksum: false)
  end
end
