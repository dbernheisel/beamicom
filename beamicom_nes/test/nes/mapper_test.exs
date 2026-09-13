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

  defp mapper_state(bus, values),
    do: %{bus | mapper_state: Map.merge(bus.mapper_state, Map.new(values))}

  # MMC1 register write = five serial writes of the low bit, LSB first.
  defp mmc1(bus, addr, val), do: Enum.reduce(0..4, bus, &Bus.write(&2, addr, val >>> &1 &&& 1))

  test "UxROM switches the $8000 bank and keeps $C000 fixed to the last bank" do
    # NES 2.0 submapper 1 identifies a conflict-free board.
    bus = mapper_state(bus(2), submapper: 1)
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

  test "MMC1 uses CHR bit 4 as the outer PRG bank on 512KB SUROM boards" do
    prg = for i <- 0..31, into: <<>>, do: :binary.copy(<<i>>, 0x4000)

    cart = %Cart{
      mapper: 1,
      prg_rom: prg,
      chr_rom: <<>>,
      prg_ram_size: 0x2000,
      mirroring: :horizontal,
      battery: false
    }

    bus = Bus.new(cart, PPU.new(<<>>, :horizontal))
    bus = bus |> mmc1(0xA000, 0x10) |> mmc1(0xE000, 2)

    assert Bus.peek(bus, 0x8000) == 18
    assert Bus.peek(bus, 0xC000) == 31
  end

  test "MMC1 banks larger PRG-RAM and honors the PRG register disable bit" do
    bus = mapper_state(bus(1), prg_ram_size: 0x8000)
    bus = bus |> mmc1(0xA000, 0x08) |> Bus.write(0x6000, 0xAA)
    assert Bus.peek(bus, 0x6000) == 0xAA

    bus = mmc1(bus, 0xA000, 0x00)
    assert Bus.peek(bus, 0x6000) == 0
    bus = Bus.write(bus, 0x6000, 0x55)

    bus = mmc1(bus, 0xA000, 0x08)
    assert Bus.peek(bus, 0x6000) == 0xAA

    bus = mmc1(bus, 0xE000, 0x10)
    assert Bus.peek(bus, 0x6000) == 0
    assert Bus.write(bus, 0x6000, 0x11).wram == bus.wram
  end

  test "MMC1 submapper 5 keeps its 32KB PRG ROM fixed" do
    bus = mapper_state(bus(1), submapper: 5) |> mmc1(0xE000, 3)
    assert Bus.peek(bus, 0x8000) == 0
    assert Bus.peek(bus, 0xC000) == 1
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

  test "MMC3 $A001 enables and write-protects PRG-RAM" do
    bus = bus(4) |> Bus.write(0x6000, 0x11) |> Bus.write(0xA001, 0x00)
    assert Bus.peek(bus, 0x6000) == 0
    assert Bus.write(bus, 0x6000, 0x22).wram == bus.wram

    bus = Bus.write(bus, 0xA001, 0xC0)
    assert Bus.peek(bus, 0x6000) == 0x11
    assert Bus.write(bus, 0x6000, 0x22).wram == bus.wram

    bus = bus |> Bus.write(0xA001, 0x80) |> Bus.write(0x6000, 0x33)
    assert Bus.peek(bus, 0x6000) == 0x33
  end

  test "MMC6 submapper controls its two mirrored 512-byte RAM halves" do
    bus = mapper_state(bus(4), submapper: 1)

    # $8000 bit 5 globally enables RAM; $A001 HhLl enables read/write per half.
    bus = bus |> Bus.write(0x8000, 0x20) |> Bus.write(0xA001, 0xF0)
    bus = bus |> Bus.write(0x7000, 0x11) |> Bus.write(0x7200, 0x22)
    assert Bus.peek(bus, 0x7000) == 0x11
    assert Bus.peek(bus, 0x7400) == 0x11
    assert Bus.peek(bus, 0x7200) == 0x22

    # Disable writes to the low half while leaving both halves readable.
    protected = Bus.write(bus, 0xA001, 0xE0)
    assert Bus.write(protected, 0x7000, 0x33).wram == protected.wram
    assert Bus.write(protected, 0x7200, 0x44) |> Bus.peek(0x7200) == 0x44

    disabled = Bus.write(protected, 0x8000, 0x00)
    assert Bus.peek(disabled, 0x7000) == 0
  end

  test "CNROM switches the 8KB CHR bank, PRG stays fixed" do
    bus = bus_chr(3) |> mapper_state(submapper: 1) |> Bus.write(0x8000, 2)
    assert chr0(bus) == 0x4000
    assert Bus.peek(bus, 0x8000) == 0
  end

  test "GxROM sets PRG (bits 4-5) and CHR (bits 0-1) from one byte" do
    # $12 → PRG 32KB bank 1 (8KB bank 4 = 16KB bank 2 = value 2), CHR 8KB bank 2.
    bus = Mapper.write(bus_chr(66), 0x8000, 0x12)
    assert Bus.peek(bus, 0x8000) == 2
    assert chr0(bus) == 0x4000
  end

  test "Color Dreams sets PRG (bits 0-1) and CHR (bits 4-7)" do
    # $21 → PRG 32KB bank 1 (value 2), CHR 8KB bank 2.
    bus = Mapper.write(bus_chr(11), 0x8000, 0x21)
    assert Bus.peek(bus, 0x8000) == 2
    assert chr0(bus) == 0x4000
  end

  test "BNROM switches its complete 32KB PRG window" do
    bus = Mapper.write(bus(34), 0x8000, 1)
    assert Bus.peek(bus, 0x8000) == 2
    assert Bus.peek(bus, 0xC000) == 3
  end

  test "discrete mappers apply board-specific bus conflicts" do
    # The fixture's visible byte at $8000 is zero, so a conflicting write is
    # masked to zero before it reaches the bank register.
    uxrom = Bus.write(bus(2), 0x8000, 2)
    assert Bus.peek(uxrom, 0x8000) == 0

    # AxROM defaults to conflict-free; NES 2.0 submapper 2 opts into conflicts.
    axrom = Bus.write(bus(7), 0x8000, 1)
    assert Bus.peek(axrom, 0x8000) == 2

    axrom_conflicting = bus(7) |> mapper_state(submapper: 2) |> Bus.write(0x8000, 1)
    assert Bus.peek(axrom_conflicting, 0x8000) == 0

    gxrom = Bus.write(bus_chr(66), 0x8000, 0x12)
    assert Bus.peek(gxrom, 0x8000) == 0
    assert chr0(gxrom) == 0

    bnrom = Bus.write(bus(34), 0x8000, 1)
    assert Bus.peek(bnrom, 0x8000) == 0
  end

  test "TxSROM derives per-nametable CIRAM pages from its CHR registers" do
    bus = bus_chr(118)

    # CHR inversion maps R2-R5 into the first pattern table and therefore makes
    # their bit 7 select each of the four 1KB nametable pages independently.
    bus = bus |> Bus.write(0x8000, 0x82) |> Bus.write(0x8001, 0x80)
    bus = bus |> Bus.write(0x8000, 0x83) |> Bus.write(0x8001, 0x00)
    bus = bus |> Bus.write(0x8000, 0x84) |> Bus.write(0x8001, 0x80)
    bus = bus |> Bus.write(0x8000, 0x85) |> Bus.write(0x8001, 0x00)

    assert bus.ppu.nt_source == {1, 0, 1, 0}
    assert Bus.write(bus, 0xA000, 0).ppu.nt_source == {1, 0, 1, 0}
  end

  test "TQROM selects CHR ROM or writable CHR RAM per bank" do
    bus = bus_chr(119) |> Bus.write(0x8000, 0) |> Bus.write(0x8001, 0x40)
    assert elem(bus.ppu.chr_banks, 0) < 0
    assert elem(bus.ppu.chr_banks, 1) < 0

    ppu =
      bus.ppu
      |> PPU.write_register(0x2006, 0)
      |> PPU.write_register(0x2006, 0)
      |> PPU.write_register(0x2007, 0xAA)

    assert ppu.chr_ram[0] == 0xAA

    rom = %{bus | ppu: ppu} |> Bus.write(0x8000, 0) |> Bus.write(0x8001, 0)
    assert elem(rom.ppu.chr_banks, 0) == 0
  end

  test "DxROM/Namco 108 switches banks without MMC3 mode or IRQ controls" do
    bus = bus_chr(206)

    # Upper bank-select bits do not exist: $C6 still selects R6.
    bus = bus |> Bus.write(0x8000, 0xC6) |> Bus.write(0x8001, 2)
    assert Bus.peek(bus, 0x8000) == 1
    assert Bus.peek(bus, 0xC000) == 3

    bus = bus |> Bus.write(0x8000, 0) |> Bus.write(0x8001, 4)
    assert elem(bus.ppu.chr_banks, 0) == 0x1000
    assert elem(bus.ppu.chr_banks, 1) == 0x1400

    unchanged = bus |> Bus.write(0xC000, 1) |> Bus.write(0xE001, 0) |> Mapper.clock_irq(2)
    refute unchanged.irq_enabled
    refute unchanged.irq_pending
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

  test "FME-7 command 8 banks ROM or enabled PRG-RAM at $6000" do
    # ROM bank 2 contains byte 1 in the fixture's 16KB-filled layout.
    bus = mapper_state(bus(69), prg_ram_size: 0x4000)
    bus = bus |> Bus.write(0x8000, 8) |> Bus.write(0xA000, 2)
    assert Bus.peek(bus, 0x6000) == 1

    # Bit 6 selects RAM and bit 7 enables it; low bits select the RAM bank.
    bus = bus |> Bus.write(0xA000, 0xC1) |> Bus.write(0x6000, 0xAA)
    assert Bus.peek(bus, 0x6000) == 0xAA
    assert Bus.write(bus, 0xA000, 0xC0) |> Bus.peek(0x6000) == 0

    disabled = Bus.write(bus, 0xA000, 0x41)
    assert Bus.peek(disabled, 0x6000) == 0
    assert Bus.write(disabled, 0x6000, 0x55).wram == disabled.wram
  end

  test "Sunsoft 5B audio ports select and write its internal registers" do
    bus = bus(69) |> Bus.write(0xC000, 2) |> Bus.write(0xE000, 0x34)
    assert elem(bus.apu.sunsoft5b.regs, 2) == 0x34
    assert bus.apu.pending == 0
  end

  test "MMC2 latch CHR register selects the bank under the default (FE) latch" do
    # $C000 sets the table-0 FE bank; the latch defaults to FE, so it's active.
    bus = Bus.write(bus_chr(9), 0xC000, 3)
    assert chr0(bus) == 0x3000
  end

  test "MMC5 banks 8KB PRG (mode 3) and sets per-nametable source" do
    bus = Bus.write(bus_chr(5), 0x5114, 0x82)
    assert Bus.peek(bus, 0x8000) == 1
    # $5105 = $44 → sources {CIRAM0, CIRAM1, CIRAM0, CIRAM1} (vertical mirroring).
    assert Bus.write(bus_chr(5), 0x5105, 0x44).ppu.nt_source == {0, 1, 0, 1}
  end

  test "MMC5 maps banked PRG-RAM into $6000 and $8000 and enforces write protection" do
    bus = mapper_state(bus_chr(5), prg_ram_size: 0x8000)

    bus =
      bus
      |> Bus.write(0x5102, 2)
      |> Bus.write(0x5103, 1)
      |> Bus.write(0x5113, 2)
      |> Bus.write(0x6000, 0x66)
      |> Bus.write(0x5114, 1)
      |> Bus.write(0x8000, 0xAA)

    assert Bus.peek(bus, 0x6000) == 0x66
    assert Bus.peek(bus, 0x8000) == 0xAA
    assert bus |> Bus.write(0x5114, 0) |> Bus.peek(0x8000) == 0
    assert bus |> Bus.write(0x5114, 0x82) |> Bus.peek(0x8000) == 1

    protected = Bus.write(bus, 0x5102, 0)
    assert Bus.write(protected, 0x8000, 0x55).wram == protected.wram
  end

  test "MMC5 reapplies latched PRG registers when its PRG mode changes" do
    bus = bus_chr(5) |> Bus.write(0x5115, 0x84) |> Bus.write(0x5100, 2)
    assert Bus.peek(bus, 0x8000) == 2
    assert Bus.peek(bus, 0xA000) == 2
    assert Bus.peek(bus, 0xE000) == 3
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

  test "MMC5 scanline IRQ: pending latches on the frame-synced scanline matching $5203, $5203=0 never matches, enable only gates the line" do
    # Enable IRQ ($5204 bit7) and target scanline 3 ($5203).
    bus = bus_chr(5) |> Bus.write(0x5204, 0x80) |> Bus.write(0x5203, 3)

    # A non-matching rendered scanline does not latch pending.
    refute (put_in(bus.ppu.irq_scanline, 2) |> Mapper.clock_irq(1)).irq_pending

    # The matching scanline latches pending and asserts /IRQ.
    bus = put_in(bus.ppu.irq_scanline, 3) |> Mapper.clock_irq(1)
    assert bus.irq_pending
    assert Bus.irq_pending?(bus)

    # Disabling the IRQ deasserts /IRQ but leaves the pending flag set (NESdev).
    bus = Bus.write(bus, 0x5204, 0x00)
    assert bus.irq_pending
    refute Bus.irq_pending?(bus)

    # $5203 = 0 is a special case: scanline 0 must never set pending.
    bus = bus_chr(5) |> Bus.write(0x5204, 0x80) |> Bus.write(0x5203, 0)
    bus = put_in(bus.ppu.irq_scanline, 0) |> Mapper.clock_irq(1)
    refute bus.irq_pending
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
