# Beamicom GBC

A dependency-free, headless Game Boy and Game Boy Color emulator core written
in Elixir. This project is intentionally separate from the NES core: hardware
timing and machine state remain system-specific, while future host integration
can share coarse-grained audio, video, input, and lifecycle boundaries.

The first milestone provides:

- Game Boy cartridge-header parsing with checksum validation
- DMG, CGB-compatible, and CGB-only identification
- Standard cartridge type and ROM/RAM size metadata
- Fixed two-bank ROM access for no-MBC cartridges
- External RAM access for no-MBC RAM cartridges
- A functional SM83/LR35902 CPU with all legal base and CB opcodes
- Cycle-ordered bus accesses with exact per-instruction M-cycle counts
- Interrupt priority/service, delayed IME, HALT/HALT-bug, and STOP behavior
- DIV/TIMA timer edges, delayed overflow reload, and interrupt registers
- CGB KEY1 normal/double-speed switching
- A separate mapped hardware bus with a flat-memory bring-up backing store

MBC1, MBC2, MBC3, MBC5, and other cartridge hardware are recognized in header
metadata but are not loaded yet.

The CPU and bus remain separate. Every CPU fetch, data read/write, and internal
idle M-cycle advances timer hardware before the next observable bus access;
the returned M-cycle count remains available to the future LCD/APU scheduler.
One instruction can be executed headlessly with:

```elixir
alias Beamicom.GB.{Bus, CPU}

bus = Bus.new(<<0x3E, 0x42>>) # LD A,$42
{cpu, bus, 2} = CPU.step(CPU.new(), bus)
cpu.a
```

## Usage

```elixir
{:ok, cartridge} = Beamicom.GB.Cartridge.load(File.read!("game.gbc"))
byte = Beamicom.GB.Cartridge.read(cartridge, 0x0100)
```

To inspect the header of a cartridge whose mapper is not implemented:

```elixir
{:ok, header} = Beamicom.GB.Header.parse(File.read!("game.gbc"))
header.mapper
```

## Tests

The tests generate synthetic ROM images and do not include commercial ROM
data.

```sh
mix test
```
