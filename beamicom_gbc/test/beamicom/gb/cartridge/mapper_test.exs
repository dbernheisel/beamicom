defmodule Beamicom.GB.Cartridge.MapperTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GB.Cartridge
  alias Beamicom.GB.Cartridge.{MBC1, MBC2, MBC3, MBC5}

  describe "MBC1" do
    test "switches and wraps the upper ROM window, translating bank zero to one" do
      assert {:ok, %MBC1{} = cartridge} = Cartridge.load(rom(type: 0x01, rom_size: 0x02))
      assert bank_at(cartridge, 0x4000) == 1

      cartridge = Cartridge.write(cartridge, 0x2000, 6)
      assert bank_at(cartridge, 0x4000) == 6
      assert Cartridge.write(cartridge, 0x2000, 6) === cartridge

      cartridge = Cartridge.write(cartridge, 0x2000, 8)
      assert bank_at(cartridge, 0x4000) == 0

      cartridge = Cartridge.write(cartridge, 0x2000, 0)
      assert bank_at(cartridge, 0x4000) == 1
    end

    test "applies high ROM bits and mode-one lower-window banking" do
      {:ok, cartridge} = Cartridge.load(rom(type: 0x01, rom_size: 0x06))

      cartridge =
        cartridge
        |> Cartridge.write(0x2000, 2)
        |> Cartridge.write(0x4000, 1)

      assert bank_at(cartridge, 0x0000) == 0
      assert bank_at(cartridge, 0x4000) == 34

      cartridge = Cartridge.write(cartridge, 0x6000, 1)
      assert bank_at(cartridge, 0x0000) == 32
      assert bank_at(cartridge, 0x4000) == 34
    end

    test "banks external RAM only in mode one and gates reads and writes" do
      {:ok, cartridge} = Cartridge.load(rom(type: 0x03, rom_size: 0x01, ram_size: 0x03))
      assert Cartridge.read(cartridge, 0xA010) == 0xFF
      assert Cartridge.write(cartridge, 0xA010, 0x44) === cartridge

      cartridge = Cartridge.write(cartridge, 0x0000, 0x0A)
      bank0 = Cartridge.write(cartridge, 0xA010, 0x11)

      bank2 =
        bank0
        |> Cartridge.write(0x6000, 1)
        |> Cartridge.write(0x4000, 2)
        |> Cartridge.write(0xA010, 0x22)

      assert Cartridge.read(bank2, 0xA010) == 0x22
      assert bank2 |> Cartridge.write(0x4000, 0) |> Cartridge.read(0xA010) == 0x11
    end
  end

  describe "MBC2" do
    test "uses address bit 8 to distinguish RAM enable and ROM bank writes" do
      {:ok, %MBC2{} = cartridge} = Cartridge.load(rom(type: 0x05, rom_size: 0x03))
      cartridge = Cartridge.write(cartridge, 0x2100, 0x0E)
      assert bank_at(cartridge, 0x4000) == 14

      unchanged_bank = Cartridge.write(cartridge, 0x2000, 0x03)
      assert bank_at(unchanged_bank, 0x4000) == 14
      assert unchanged_bank.ram_enabled == false

      cartridge = Cartridge.write(cartridge, 0x2100, 0)
      assert bank_at(cartridge, 0x4000) == 1
    end

    test "stores low nibbles in 512 mirrored cells and returns high bits set" do
      {:ok, cartridge} = Cartridge.load(rom(type: 0x06, rom_size: 0x01))
      assert Cartridge.read(cartridge, 0xA020) == 0xFF
      assert Cartridge.write(cartridge, 0xA020, 0xAB) === cartridge

      cartridge = cartridge |> Cartridge.write(0x0000, 0x0A) |> Cartridge.write(0xA020, 0xAB)
      assert Cartridge.read(cartridge, 0xA020) == 0xFB
      assert Cartridge.read(cartridge, 0xA220) == 0xFB
      assert Cartridge.write(cartridge, 0xA220, 0x0B) === cartridge

      disabled = Cartridge.write(cartridge, 0x0000, 0)
      assert Cartridge.read(disabled, 0xA020) == 0xFF
    end
  end

  describe "MBC3" do
    test "returns identical state for RTC operations on a timer-less cartridge" do
      {:ok, cartridge} = Cartridge.load(rom(type: 0x11, rom_size: 0x01))

      assert Cartridge.write(cartridge, 0x4000, 0x08) === cartridge
      assert Cartridge.write(cartridge, 0x6000, 0) === cartridge
      assert Cartridge.advance_rtc(cartridge, 86_400) === cartridge
    end

    test "switches ROM and RAM banks with precomputed wrapped offsets" do
      {:ok, %MBC3{} = cartridge} =
        Cartridge.load(rom(type: 0x13, rom_size: 0x02, ram_size: 0x03))

      cartridge = cartridge |> Cartridge.write(0x2000, 7) |> Cartridge.write(0x0000, 0x0A)
      assert bank_at(cartridge, 0x4000) == 7
      cartridge = Cartridge.write(cartridge, 0x2000, 0)
      assert bank_at(cartridge, 0x4000) == 1

      bank3 = cartridge |> Cartridge.write(0x4000, 3) |> Cartridge.write(0xA000, 0x33)
      assert Cartridge.read(bank3, 0xA000) == 0x33
      assert bank3 |> Cartridge.write(0x4000, 0) |> Cartridge.read(0xA000) == 0
      assert bank3 |> Cartridge.write(0x4000, 7) |> Cartridge.read(0xA000) == 0x33
    end

    test "injects, selects, writes, and advances RTC state deterministically" do
      rtc = %{seconds: 58, minutes: 59, hours: 23, days: 4, halt: false, carry: false}
      {:ok, cartridge} = Cartridge.load(rom(type: 0x0F, rom_size: 0x01), rtc: rtc)
      cartridge = Cartridge.write(cartridge, 0x0000, 0x0A)

      seconds = Cartridge.write(cartridge, 0x4000, 0x08)
      assert Cartridge.read(seconds, 0xA000) == 58

      advanced = Cartridge.advance_rtc(seconds, 2)
      assert Cartridge.read(advanced, 0xA000) == 0
      assert advanced.rtc.minutes == 0
      assert advanced.rtc.hours == 0
      assert advanced.rtc.days == 5

      minutes = Cartridge.write(advanced, 0x4000, 0x09)
      minutes = Cartridge.write(minutes, 0xA000, 12)
      assert minutes.rtc.minutes == 12
    end

    test "latches a stable RTC snapshot only on a zero-to-one sequence" do
      {:ok, cartridge} =
        Cartridge.load(rom(type: 0x0F, rom_size: 0x01), rtc: %{seconds: 10})

      cartridge =
        cartridge
        |> Cartridge.write(0x0000, 0x0A)
        |> Cartridge.write(0x4000, 0x08)
        |> Cartridge.write(0x6000, 0)
        |> Cartridge.write(0x6000, 1)

      advanced = Cartridge.advance_rtc(cartridge, 5)
      assert advanced.rtc.seconds == 15
      assert Cartridge.read(advanced, 0xA000) == 10

      relatched = advanced |> Cartridge.write(0x6000, 0) |> Cartridge.write(0x6000, 1)
      assert Cartridge.read(relatched, 0xA000) == 15
    end

    test "honors halt and sets carry when the 9-bit day counter wraps" do
      {:ok, cartridge} =
        Cartridge.load(
          rom(type: 0x0F, rom_size: 0x01),
          rtc: %{seconds: 59, minutes: 59, hours: 23, days: 511, halt: true}
        )

      assert Cartridge.advance_rtc(cartridge, 1) === cartridge

      enabled = Cartridge.write(cartridge, 0x0000, 0x0A)
      control = Cartridge.write(enabled, 0x4000, 0x0C)
      running = Cartridge.write(control, 0xA000, 0x01)
      wrapped = Cartridge.advance_rtc(running, 1)
      assert wrapped.rtc.days == 0
      assert wrapped.rtc.carry
    end

    test "round-trips RAM and RTC persistence without wall-clock adjustment" do
      {:ok, cartridge} =
        Cartridge.load(
          rom(type: 0x10, rom_size: 0x01, ram_size: 0x02),
          rtc: %{seconds: 7, days: 123, carry: true}
        )

      cartridge =
        cartridge
        |> Cartridge.write(0x0000, 0x0A)
        |> Cartridge.write(0xA123, 0x5A)

      persisted = Cartridge.persistent_data(cartridge)

      {:ok, restored} =
        Cartridge.load(rom(type: 0x10, rom_size: 0x01, ram_size: 0x02), persistence: persisted)

      restored = Cartridge.write(restored, 0x0000, 0x0A)
      assert Cartridge.read(restored, 0xA123) == 0x5A
      assert restored.rtc.seconds == 7
      assert restored.rtc.days == 123
      assert restored.rtc.carry
    end
  end

  describe "MBC5" do
    test "selects all nine ROM bank bits and permits bank zero in the upper window" do
      {:ok, %MBC5{} = cartridge} = Cartridge.load(rom(type: 0x19, rom_size: 0x08))

      bank257 = cartridge |> Cartridge.write(0x2000, 1) |> Cartridge.write(0x3000, 1)
      assert bank_at(bank257, 0x4000) == 257

      bank0 = bank257 |> Cartridge.write(0x2000, 0) |> Cartridge.write(0x3000, 0)
      assert bank_at(bank0, 0x4000) == 0
    end

    test "banks RAM and separates the rumble bit from the bank number" do
      {:ok, cartridge} =
        Cartridge.load(rom(type: 0x1D, rom_size: 0x01, ram_size: 0x03))

      assert Cartridge.write(cartridge, 0xA010, 0x77) === cartridge

      bank3 =
        cartridge
        |> Cartridge.write(0x0000, 0x0A)
        |> Cartridge.write(0x4000, 0x0B)
        |> Cartridge.write(0xA010, 0x77)

      assert bank3.rumble
      assert bank3.ram_bank == 3
      assert Cartridge.read(bank3, 0xA010) == 0x77
      assert bank3 |> Cartridge.write(0x4000, 0) |> Cartridge.read(0xA010) == 0
    end

    test "writes the full 128 KiB RAM capacity without rebuilding its other pages" do
      {:ok, cartridge} =
        Cartridge.load(rom(type: 0x1B, rom_size: 0x01, ram_size: 0x04))

      enabled = Cartridge.write(cartridge, 0x0000, 0x0A)
      original_pages = enabled.ram.pages

      bank15 =
        enabled
        |> Cartridge.write(0x4000, 15)
        |> Cartridge.write(0xBFFF, 0xC7)

      assert Cartridge.read(bank15, 0xBFFF) == 0xC7
      assert bank15 |> Cartridge.write(0x4000, 0) |> Cartridge.read(0xBFFF) == 0
      assert bank15.ram_page_offset == 15 * 32

      changed_page = 511

      refute :erts_debug.same(
               elem(original_pages, changed_page),
               elem(bank15.ram.pages, changed_page)
             )

      assert :erts_debug.same(elem(original_pages, 0), elem(bank15.ram.pages, 0))
      assert Cartridge.write(bank15, 0xBFFF, 0xC7) === bank15

      persisted = Cartridge.persistent_data(bank15)
      assert byte_size(persisted.ram) == 128 * 1024
      assert :binary.at(persisted.ram, 128 * 1024 - 1) == 0xC7
    end
  end

  test "rejects mapper capacities beyond the implemented hardware" do
    assert {:error, {:unsupported_mbc1_rom_banks, 512}} =
             Cartridge.load(rom(type: 0x01, rom_size: 0x08))

    assert {:error, {:unsupported_mbc2_rom_banks, 32}} =
             Cartridge.load(rom(type: 0x05, rom_size: 0x04))

    assert {:error, {:unsupported_mbc1_rom_ram_combination, 128, 32_768}} =
             Cartridge.load(rom(type: 0x03, rom_size: 0x06, ram_size: 0x03))

    assert {:error, {:unsupported_mbc5_rumble_ram_size, 131_072}} =
             Cartridge.load(rom(type: 0x1D, rom_size: 0x01, ram_size: 0x04))
  end

  defp bank_at(cartridge, address) do
    Cartridge.read(cartridge, address) ||| Cartridge.read(cartridge, address + 1) <<< 8
  end

  defp rom(opts) do
    type = Keyword.fetch!(opts, :type)
    rom_size = Keyword.fetch!(opts, :rom_size)
    ram_size = Keyword.get(opts, :ram_size, 0)
    banks = rom_banks(rom_size)

    0..(banks - 1)
    |> Enum.map(fn bank ->
      <<bank &&& 0xFF, bank >>> 8>> <> :binary.copy(<<bank &&& 0xFF>>, 0x3FFE)
    end)
    |> IO.iodata_to_binary()
    |> put_bytes(0x134, "MAPPER TEST" <> :binary.copy(<<0>>, 5))
    |> put_byte(0x143, 0)
    |> put_byte(0x147, type)
    |> put_byte(0x148, rom_size)
    |> put_byte(0x149, ram_size)
    |> with_checksum()
  end

  defp rom_banks(0x00), do: 2
  defp rom_banks(0x01), do: 4
  defp rom_banks(0x02), do: 8
  defp rom_banks(0x03), do: 16
  defp rom_banks(0x04), do: 32
  defp rom_banks(0x06), do: 128
  defp rom_banks(0x08), do: 512

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix_offset = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
  end
end
