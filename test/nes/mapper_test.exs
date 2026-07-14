defmodule Beamicom.NES.MapperTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.NES.{Bus, Cart, Mapper, PPU}

  @moduledoc "Bank switching across all implemented mappers — spec §5.3, §9."

  # 4 PRG banks of 16KB, each filled with its bank number for easy identification.
  defp cart(mapper, chr \\ <<>>) do
    prg = for i <- 0..3, into: <<>>, do: :binary.copy(<<i>>, 0x4000)
    %Cart{mapper: mapper, prg_rom: prg, chr_rom: chr, mirroring: :horizontal, battery: false}
  end

  defp bus(mapper), do: Bus.new(cart(mapper), PPU.new(<<>>, :horizontal))

  # 32KB CHR-ROM so 8KB/4KB/1KB bank offsets don't wrap; the PPU holds the CHR.
  defp bus_chr(mapper) do
    chr = :binary.copy(<<0>>, 0x8000)
    Bus.new(cart(mapper, chr), PPU.new(chr, :horizontal))
  end

  defp chr0(bus), do: elem(bus.ppu.chr_banks, 0)

  # MMC1 register write = five serial writes of the low bit, LSB first.
  defp mmc1(bus, addr, val), do: Enum.reduce(0..4, bus, &Bus.write(&2, addr, val >>> &1 &&& 1))

  test "UxROM switches the $8000 bank and keeps $C000 fixed to the last bank" do
    bus = bus(2)
    assert Bus.peek(bus, 0x8000) == 0
    assert Bus.peek(bus, 0xC000) == 3

    bus = Bus.write(bus, 0x8000, 2)
    assert Bus.peek(bus, 0x8000) == 2
    assert Bus.peek(bus, 0xC000) == 3
  end

  test "MMC1 boots with bank 0 at $8000 and the last bank fixed at $C000" do
    bus = bus(1)
    assert Bus.peek(bus, 0x8000) == 0
    assert Bus.peek(bus, 0xC000) == 3
  end

  test "MMC1 selects the $8000 PRG bank via the serial shift register" do
    bus = mmc1(bus(1), 0xE000, 2)
    assert Bus.peek(bus, 0x8000) == 2
    assert Bus.peek(bus, 0xC000) == 3
  end

  test "MMC1 control register sets nametable mirroring" do
    # 0x0E = PRG mode 3 (bits 2-3) + vertical mirroring (bits 0-1 = 2).
    bus = mmc1(bus(1), 0x8000, 0x0E)
    assert bus.ppu.mirroring == :vertical
  end

  test "MMC3 switches an 8KB PRG bank via bank-select then bank-data" do
    bus = bus(4)
    assert Bus.peek(bus, 0x8000) == 0

    # Select R6 ($8000 bank) and point it at 8KB bank 2 (lives in 16KB bank 1).
    bus = bus |> Bus.write(0x8000, 6) |> Bus.write(0x8001, 2)
    assert Bus.peek(bus, 0x8000) == 1
  end

  test "MMC3 sets mirroring via $A000" do
    assert Bus.write(bus(4), 0xA000, 1).ppu.mirroring == :horizontal
    assert Bus.write(bus(4), 0xA000, 0).ppu.mirroring == :vertical
  end

  test "MMC3 asserts IRQ when the scanline counter reaches zero" do
    bus =
      bus(4)
      |> Bus.write(0xC000, 2)
      |> Bus.write(0xC001, 0)
      |> Bus.write(0xE001, 0)

    bus = Mapper.clock_irq(bus, 1)
    refute bus.irq_pending
    bus = Mapper.clock_irq(bus, 1)
    refute bus.irq_pending
    bus = Mapper.clock_irq(bus, 1)
    assert bus.irq_pending
  end

  test "CNROM switches the 8KB CHR bank, PRG stays fixed" do
    bus = Bus.write(bus_chr(3), 0x8000, 2)
    assert chr0(bus) == 0x4000
    assert Bus.peek(bus, 0x8000) == 0
  end

  test "GxROM sets PRG (bits 4-5) and CHR (bits 0-1) from one byte" do
    # $12 → PRG 32KB bank 1 (8KB bank 4 = 16KB bank 2 = value 2), CHR 8KB bank 2.
    bus = Bus.write(bus_chr(66), 0x8000, 0x12)
    assert Bus.peek(bus, 0x8000) == 2
    assert chr0(bus) == 0x4000
  end

  test "Color Dreams sets PRG (bits 0-1) and CHR (bits 4-7)" do
    # $21 → PRG 32KB bank 1 (value 2), CHR 8KB bank 2.
    bus = Bus.write(bus_chr(11), 0x8000, 0x21)
    assert Bus.peek(bus, 0x8000) == 2
    assert chr0(bus) == 0x4000
  end

  test "FME-7 selects an 8KB PRG bank via command + parameter ports" do
    # cmd 9 = PRG $8000; param 2 → 8KB bank 2 = 16KB bank 1 = value 1.
    bus = bus(69) |> Bus.write(0x8000, 9) |> Bus.write(0xA000, 2)
    assert Bus.peek(bus, 0x8000) == 1
  end

  test "FME-7 asserts a CPU-cycle IRQ on counter underflow" do
    # counter = 2, counter+IRQ enabled ($D bit0 + bit7).
    bus =
      bus(69)
      |> Bus.write(0x8000, 15)
      |> Bus.write(0xA000, 0)
      |> Bus.write(0x8000, 14)
      |> Bus.write(0xA000, 2)
      |> Bus.write(0x8000, 13)
      |> Bus.write(0xA000, 0x81)

    refute Mapper.clock_cpu_irq(bus, 2).irq_pending
    assert Mapper.clock_cpu_irq(bus, 3).irq_pending
  end

  test "MMC2 latch CHR register selects the bank under the default (FE) latch" do
    # $C000 sets the table-0 FE bank; the latch defaults to FE, so it's active.
    bus = Bus.write(bus_chr(9), 0xC000, 3)
    assert chr0(bus) == 0x3000
  end

  test "MMC5 banks 8KB PRG (mode 3) and sets per-nametable source" do
    bus = Bus.write(bus_chr(5), 0x5114, 2)
    assert Bus.peek(bus, 0x8000) == 1
    # $5105 = $44 → sources {CIRAM0, CIRAM1, CIRAM0, CIRAM1} (vertical mirroring).
    assert Bus.write(bus_chr(5), 0x5105, 0x44).ppu.nt_source == {0, 1, 0, 1}
  end

  test "MMC5 keeps separate sprite ($5120-27) and background ($5128-2B) CHR banks" do
    # CHR mode 3 (1KB windows): sprite window 0 = bank 2, background window 0 = bank 5.
    bus = bus_chr(5) |> Bus.write(0x5120, 2) |> Bus.write(0x5128, 5)
    assert elem(bus.ppu.chr_banks, 0) == 2 * 0x400
    assert elem(bus.ppu.bg_chr_banks, 0) == 5 * 0x400
  end

  test "MMC5 CHR mode 0 maps one 8KB bank across all eight 1KB windows" do
    # $5101=0 (8KB), $5127 selects the 8KB bank.
    bus = bus_chr(5) |> Bus.write(0x5101, 0) |> Bus.write(0x5127, 1)
    assert elem(bus.ppu.chr_banks, 0) == 0x2000
    assert elem(bus.ppu.chr_banks, 7) == 0x2000 + 7 * 0x400
  end

  test "MMC5 executes and reads back ExRAM in work-RAM mode" do
    bus = bus_chr(5) |> Bus.write(0x5104, 2) |> Bus.write(0x5C00, 0xA9)
    assert Bus.peek(bus, 0x5C00) == 0xA9
    assert {0xA9, _} = Bus.read(bus, 0x5C00)
  end

  test "MMC5 vertical split registers decode into PPU state" do
    bus =
      bus_chr(5)
      # $84 = enable (bit7) + side 0 (bit6) + threshold 4 (bits 0-4).
      |> Bus.write(0x5200, 0x84)
      |> Bus.write(0x5201, 30)
      |> Bus.write(0x5202, 3)

    assert %{split_en: true, split_side: 0, split_tile: 4, split_scroll: 30, split_chr: 3} =
             bus.ppu
  end
end
