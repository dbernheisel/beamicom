defmodule Beamicom.GB.BusTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.{Bus, Cartridge}

  test "flat memory loads, reads, and writes bytes" do
    bus = Bus.new(<<0x12, 0x34>>) |> Bus.load(0xFFFE, <<0xAB, 0xCD>>)

    assert Bus.read(bus, 0) == 0x12
    assert Bus.read(bus, 1) == 0x34
    assert Bus.read(bus, 0x8000) == 0
    assert Bus.read(bus, 0xFFFE) == 0xAB
    assert Bus.read(bus, 0xFFFF) == 0xCD

    changed = Bus.write(bus, 0x8000, 0xEF)
    assert Bus.read(changed, 0x8000) == 0xEF
    assert Bus.read(bus, 0x8000) == 0
  end

  test "16-bit accesses are little endian and wrap at the address boundary" do
    bus = Bus.new() |> Bus.write16(0xFFFF, 0xBEEF)

    assert Bus.read(bus, 0xFFFF) == 0xEF
    assert Bus.read(bus, 0) == 0xBE
    assert Bus.read16(bus, 0xFFFF) == 0xBEEF
  end

  test "interrupt and timer registers are projected instead of duplicated in flat memory" do
    bus =
      Bus.new()
      |> Bus.write(0xFF0F, 0xFF)
      |> Bus.write(0xFFFF, 0xA5)
      |> Bus.write(0xFF05, 0x12)
      |> Bus.write(0xFF06, 0x34)
      |> Bus.write(0xFF07, 0xFF)

    assert Bus.read(bus, 0xFF0F) == 0xFF
    assert Bus.read(bus, 0xFFFF) == 0xA5
    assert Bus.read(bus, 0xFF05) == 0x12
    assert Bus.read(bus, 0xFF06) == 0x34
    assert Bus.read(bus, 0xFF07) == 0xFF
    assert Bus.pending_interrupts(bus) == 0x05
  end

  test "interrupt requests use literal masks and acknowledgement clears only its source" do
    bus =
      Bus.new()
      |> Bus.request_interrupt(:vblank)
      |> Bus.request_interrupt(:timer)
      |> Bus.request_interrupt(:joypad)

    assert Bus.read(bus, 0xFF0F) == 0xF5
    assert Bus.read(Bus.acknowledge_interrupt(bus, 0x04), 0xFF0F) == 0xF1
  end

  test "divider advances in exact T-cycles and disabled timer takes the batched path" do
    bus = Bus.tick(Bus.new(), 0x10104)
    assert bus.divider == 0x0104
    assert Bus.read(bus, 0xFF04) == 1
    assert bus.tima == 0

    bus = Bus.write(bus, 0xFF04, 0x99)
    assert bus.divider == 0
    assert Bus.read(bus, 0xFF04) == 0
  end

  test "each TAC clock selection increments TIMA on the selected falling edge" do
    for {select, period} <- [{0, 1024}, {1, 16}, {2, 64}, {3, 256}] do
      bus = Bus.new() |> Bus.write(0xFF07, 0x04 ||| select)
      bus = Bus.tick(bus, period - 1)
      assert bus.tima == 0, "TAC frequency #{select} incremented early"
      assert Bus.tick(bus, 1).tima == 1
    end
  end

  test "DIV reset and TAC changes honor timer-input falling-edge glitches" do
    high_bit_3 = Bus.tick(Bus.new(), 8)

    div_glitch = high_bit_3 |> Bus.write(0xFF07, 0x05) |> Bus.write(0xFF04, 0)
    assert div_glitch.tima == 1

    tac_glitch = high_bit_3 |> Bus.write(0xFF07, 0x05) |> Bus.write(0xFF07, 0)
    assert tac_glitch.tima == 1
  end

  test "TIMA overflow reloads TMA and requests IRQ four T-cycles later" do
    bus =
      Bus.new()
      |> Bus.write(0xFF05, 0xFF)
      |> Bus.write(0xFF06, 0xA7)
      |> Bus.write(0xFF07, 0x05)
      |> Bus.tick(16)

    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0, 4, 0}

    bus = Bus.tick(bus, 3)
    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0, 1, 0}

    bus = Bus.tick(bus, 1)
    assert {bus.tima, bus.timer_reload, bus.interrupt_flags} == {0xA7, 0, 0x04}
  end

  test "TIMA writes cancel a pending reload while TMA writes affect it" do
    overflowed =
      Bus.new()
      |> Bus.write(0xFF05, 0xFF)
      |> Bus.write(0xFF07, 0x05)
      |> Bus.tick(16)

    cancelled = overflowed |> Bus.write(0xFF05, 0x55) |> Bus.tick(4)
    assert {cancelled.tima, cancelled.timer_reload, cancelled.interrupt_flags} == {0x55, 0, 0}

    reloaded = overflowed |> Bus.write(0xFF06, 0x66) |> Bus.tick(4)
    assert {reloaded.tima, reloaded.interrupt_flags} == {0x66, 0x04}
  end

  test "KEY1 is CGB-only and retains only current and prepared speed bits" do
    dmg = Bus.new() |> Bus.write(0xFF4D, 1)
    assert Bus.read(dmg, 0xFF4D) == 0xFF
    refute Bus.cgb?(dmg)

    cgb = Bus.new(<<>>, model: :cgb) |> Bus.tick(0x1234) |> Bus.write(0xFF4D, 0xFF)
    assert Bus.cgb?(cgb)
    refute Bus.double_speed?(cgb)
    assert Bus.read(cgb, 0xFF4D) == 0x7F

    {:speed_switch, cgb} = Bus.stop(cgb)
    assert Bus.double_speed?(cgb)
    assert cgb.divider == 0
    assert Bus.read(cgb, 0xFF4D) == 0xFE
  end

  test "CGB speed switching currently toggles immediately without the oscillator delay" do
    bus = mapped_bus(model: :cgb) |> Bus.write(0xFF40, 0x80) |> Bus.tick(100)
    clock = bus.ppu.clock
    bus = bus |> Bus.write(0xFF4D, 1) |> Map.put(:divider, 0x1234)

    assert {:speed_switch, switched} = Bus.stop(bus)
    assert Bus.double_speed?(switched)
    assert switched.divider == 0
    assert switched.ppu.clock == clock
  end

  describe "production memory map" do
    test "keeps flat test memory distinct from cartridge-backed buses" do
      flat = Bus.new_flat(<<0x12, 0x34>>)
      mapped = mapped_bus()

      assert {flat.mode, flat.cartridge, Bus.read(flat, 0)} == {:flat, nil, 0x12}
      assert mapped.mode == :mapped
      assert mapped.memory == nil
      assert Bus.read(mapped, 0) == 0x21
      assert Bus.read(mapped, 0x4000) == 0x84
    end

    test "routes cartridge RAM and mapper-window writes through Cartridge" do
      bus = mapped_bus(type: 0x08, ram_size: 0x02)
      bus = Bus.write(bus, 0xA123, 0x5A)

      assert Bus.read(bus, 0xA123) == 0x5A
      assert Cartridge.read(bus.cartridge, 0xA123) == 0x5A
      assert Bus.write(bus, 0x2000, 0x07).cartridge == bus.cartridge
    end

    test "selects both CGB VRAM banks while DMG remains on bank zero" do
      cgb = mapped_bus(model: :cgb) |> Bus.write(0x8004, 0x11)
      cgb = cgb |> Bus.write(0xFF4F, 1) |> Bus.write(0x8004, 0x22)

      assert Bus.read(cgb, 0x8004) == 0x22
      assert Bus.read(Bus.write(cgb, 0xFF4F, 0), 0x8004) == 0x11
      assert Bus.read(cgb, 0xFF4F) == 0xFF

      dmg = mapped_bus() |> Bus.write(0x8004, 0x33) |> Bus.write(0xFF4F, 1)
      assert Bus.read(dmg, 0x8004) == 0x33
      assert Bus.read(dmg, 0xFF4F) == 0xFF
    end

    test "routes CGB palette RAM and leaves the registers unmapped on DMG" do
      cgb =
        mapped_bus(model: :cgb)
        |> Bus.write(0xFF68, 0x80 ||| 6)
        |> Bus.write(0xFF69, 0x34)
        |> Bus.write(0xFF69, 0x12)

      assert Bus.read(cgb, 0xFF68) == 0x88
      cgb = Bus.write(cgb, 0xFF68, 6)
      assert Bus.read(cgb, 0xFF69) == 0x34

      cgb = cgb |> Bus.write(0xFF40, 0x80) |> Bus.tick(80)
      cgb = cgb |> Bus.write(0xFF68, 0x86) |> Bus.write(0xFF69, 0)
      assert Bus.read(cgb, 0xFF68) == 0x87
      assert Bus.read(cgb, 0xFF69) == 0xFF

      dmg = mapped_bus() |> Bus.write(0xFF68, 0x80) |> Bus.write(0xFF69, 0x34)
      assert Bus.read(dmg, 0xFF68) == 0xFF
      assert Bus.read(dmg, 0xFF69) == 0xFF
    end

    test "maps fixed and banked WRAM through the echo range" do
      bus = mapped_bus(model: :cgb)
      bus = bus |> Bus.write(0xC123, 0x10) |> Bus.write(0xD123, 0x21)
      assert Bus.read(bus, 0xE123) == 0x10
      assert Bus.read(bus, 0xF123) == 0x21

      bus = bus |> Bus.write(0xFF70, 3) |> Bus.write(0xD123, 0x43)
      assert Bus.read(bus, 0xD123) == 0x43
      assert Bus.read(bus, 0xF123) == 0x43
      assert Bus.read(Bus.write(bus, 0xFF70, 1), 0xD123) == 0x21

      bank_one = Bus.write(bus, 0xFF70, 0)
      assert Bus.read(bank_one, 0xFF70) == 0xF8
      assert Bus.read(bank_one, 0xD123) == 0x21
    end

    test "maps OAM and HRAM and leaves the unusable range open" do
      bus =
        mapped_bus()
        |> Bus.write(0xFE9F, 0xA5)
        |> Bus.write(0xFEA0, 0x33)
        |> Bus.write(0xFF80, 0xC1)
        |> Bus.write(0xFFFE, 0xD2)

      assert Bus.read(bus, 0xFE9F) == 0xA5
      assert Bus.read(bus, 0xFEA0) == 0xFF
      assert Bus.read(bus, 0xFEFF) == 0xFF
      assert Bus.read(bus, 0xFF80) == 0xC1
      assert Bus.read(bus, 0xFFFE) == 0xD2
    end

    test "overlays DMG and CGB boot-ROM regions until FF50 disables them" do
      dmg = mapped_bus(boot_rom: :binary.copy(<<0xE1>>, 0x100))
      assert Bus.read(dmg, 0) == 0xE1
      assert Bus.read(dmg, 0x00FF) == 0xE1
      assert Bus.read(dmg, 0x0100) == 0x21

      dmg = Bus.write(dmg, 0xFF50, 1)
      assert Bus.read(dmg, 0) == 0x21
      refute Bus.write(dmg, 0xFF50, 0).boot_enabled

      boot = :binary.copy(<<0xD4>>, 0x900)
      cgb = mapped_bus(model: :cgb, boot_rom: boot)
      assert Bus.read(cgb, 0x00FF) == 0xD4
      assert Bus.read(cgb, 0x0100) == 0x21
      assert Bus.read(cgb, 0x0200) == 0xD4
      assert Bus.read(cgb, 0x08FF) == 0xD4
    end
  end

  describe "mapped I/O seams" do
    test "joypad selection is active-low and requests only falling selected inputs" do
      bus = mapped_bus() |> Bus.write(0xFF00, 0x20)
      assert Bus.read(bus, 0xFF00) == 0xEF

      bus = Bus.set_buttons(bus, [:right, :up, :a])
      assert Bus.read(bus, 0xFF00) == 0xEA
      assert bus.interrupt_flags == 0x10

      bus = bus |> Bus.write(0xFF0F, 0) |> Bus.write(0xFF00, 0x30) |> Bus.write(0xFF00, 0x10)
      assert Bus.read(bus, 0xFF00) == 0xDE
      assert bus.interrupt_flags == 0x10
    end

    test "serial test output drains in order and completes with an interrupt" do
      bus =
        mapped_bus()
        |> Bus.write(0xFF01, ?O)
        |> Bus.write(0xFF02, 0x81)
        |> Bus.write(0xFF01, ?K)
        |> Bus.write(0xFF02, 0x81)

      assert Bus.read(bus, 0xFF01) == 0xFF
      assert Bus.read(bus, 0xFF02) == 0x7F
      assert (bus.interrupt_flags &&& 0x08) != 0
      assert {"OK", bus} = Bus.take_serial_output(bus)
      assert {"", _bus} = Bus.take_serial_output(bus)
    end

    test "no pending DMA preserves the exact bus state without advancing devices" do
      bus = mapped_bus(model: :cgb)

      assert {^bus, 0} = Bus.run_dma(bus, false)
      assert {^bus, 0} = Bus.run_dma(bus, true)
    end

    test "OAM DMA batches 160 bytes and stalls for 160 CPU M-cycles" do
      bus =
        Enum.reduce(0..0x9F, mapped_bus(), fn offset, bus ->
          Bus.write(bus, 0xC100 + offset, offset * 3 &&& 0xFF)
        end)
        |> Bus.write(0xFF46, 0xC1)

      assert {bus, 160} = Bus.run_dma(bus)
      assert bus.oam_dma == nil
      assert bus.divider == 640
      assert bus.ppu.oam == for(offset <- 0..0x9F, into: <<>>, do: <<offset * 3 &&& 0xFF>>)

      double =
        mapped_bus(model: :cgb)
        |> Bus.write(0xFF40, 0x80)
        |> Bus.write(0xFF4D, 1)
        |> then(&elem(Bus.stop(&1), 1))
        |> Bus.write(0xFF46, 0xC0)

      assert {double, 160} = Bus.run_dma(double)
      assert double.ppu.clock == 320
      assert double.divider == 640
    end

    test "CGB general DMA copies complete blocks to the selected VRAM bank" do
      cgb =
        Enum.reduce(0..31, mapped_bus(model: :cgb), fn offset, bus ->
          Bus.write(bus, 0xC000 + offset, 0x80 + offset)
        end)
        |> Bus.write(0xFF4F, 1)
        |> Bus.write(0xFF51, 0xC0)
        |> Bus.write(0xFF52, 0x0F)
        |> Bus.write(0xFF53, 0xE0)
        |> Bus.write(0xFF54, 0x0F)
        |> Bus.write(0xFF55, 0x01)

      assert Bus.read(cgb, 0xFF51) == 0xFF
      assert Bus.read(cgb, 0xFF52) == 0xFF
      assert Bus.read(cgb, 0xFF53) == 0xFF
      assert Bus.read(cgb, 0xFF54) == 0xFF
      assert {cgb, 16} = Bus.run_dma(cgb)
      assert Bus.read(cgb, 0xFF55) == 0xFF

      assert for(address <- 0x8000..0x801F, do: Bus.read(cgb, address)) ==
               Enum.to_list(0x80..0x9F)

      bank_zero = Bus.write(cgb, 0xFF4F, 0)

      assert for(address <- 0x8000..0x801F, do: Bus.read(bank_zero, address)) ==
               List.duplicate(0, 32)
    end

    test "CGB HBlank DMA transfers one block per visible HBlank and can be cancelled" do
      cgb =
        Enum.reduce(0..47, mapped_bus(model: :cgb), fn offset, bus ->
          Bus.write(bus, 0xC100 + offset, 0x40 + offset)
        end)
        |> Bus.write(0xFF40, 0x80)
        |> Bus.write(0xFF51, 0xC1)
        |> Bus.write(0xFF52, 0)
        |> Bus.write(0xFF53, 0)
        |> Bus.write(0xFF54, 0)
        |> Bus.write(0xFF55, 0x82)
        |> Bus.tick(252)

      assert {cgb, 8} = Bus.run_dma(cgb)
      assert Bus.read(cgb, 0xFF55) == 0x01

      assert for(address <- 0x8000..0x800F, do: Bus.read(cgb, address)) ==
               Enum.to_list(0x40..0x4F)

      assert {continued, 8} = cgb |> Bus.tick(424) |> Bus.run_dma()
      assert Bus.read(continued, 0xFF55) == 0

      assert for(address <- 0x8010..0x801F, do: Bus.read(continued, address)) ==
               Enum.to_list(0x50..0x5F)

      assert {completed, 8} = continued |> Bus.tick(424) |> Bus.run_dma()
      assert Bus.read(completed, 0xFF55) == 0xFF

      assert for(address <- 0x8020..0x802F, do: Bus.read(completed, address)) ==
               Enum.to_list(0x60..0x6F)

      cancelled = Bus.write(cgb, 0xFF55, 0)
      assert Bus.read(cancelled, 0xFF55) == 0x81
      assert {cancelled, 0} = cancelled |> Bus.tick(456) |> Bus.run_dma()

      assert for(address <- 0x8010..0x802F, do: Bus.read(cancelled, address)) ==
               List.duplicate(0, 32)
    end

    test "VRAM DMA keeps an eight-dot-domain M-cycle duration in double speed" do
      cgb =
        mapped_bus(model: :cgb)
        |> Bus.write(0xC000, 0xA5)
        |> Bus.write(0xFF40, 0x80)
        |> Bus.write(0xFF4D, 1)
        |> then(&elem(Bus.stop(&1), 1))
        |> Bus.write(0xFF51, 0xC0)
        |> Bus.write(0xFF52, 0)
        |> Bus.write(0xFF53, 0)
        |> Bus.write(0xFF54, 0)
        |> Bus.write(0xFF55, 0)

      assert {cgb, 16} = Bus.run_dma(cgb)
      assert cgb.ppu.clock == 32
      assert cgb.divider == 64
      assert Bus.read(cgb, 0x8000) == 0xA5
    end
  end

  defp mapped_bus(opts \\ []) do
    bus_keys = [:model, :boot_rom]
    cartridge_opts = Keyword.drop(opts, bus_keys)
    bus_opts = Keyword.take(opts, bus_keys)
    {:ok, cartridge} = Cartridge.load(rom(cartridge_opts))
    Bus.new(cartridge, bus_opts)
  end

  defp rom(opts) do
    bank0 = Keyword.get(opts, :bank0, 0x21)
    bank1 = Keyword.get(opts, :bank1, 0x84)
    type = Keyword.get(opts, :type, 0x00)
    ram_size = Keyword.get(opts, :ram_size, 0x00)

    (:binary.copy(<<bank0>>, 0x4000) <> :binary.copy(<<bank1>>, 0x4000))
    |> put_bytes(0x134, "BUS TEST" <> :binary.copy(<<0>>, 8))
    |> put_byte(0x143, 0)
    |> put_byte(0x147, type)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, ram_size)
    |> with_checksum()
  end

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
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
