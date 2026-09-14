# Beamicom SNES

A dependency-free Super NES core written in Elixir. The native implementation
currently establishes:

- copier-header detection and LoROM, HiROM, and ExHiROM header selection;
- SNES header metadata and mirrored ROM addressing, including non-power-of-two
  images such as 3 MiB cartridges;
- the CPU-visible WRAM, MMIO, and cartridge ROM map with slow/fast access costs;
- an NTSC/PAL master-clock beam counter with NMI and H/V timer IRQs;
- native Mode 0/1 background rendering and the initial S-PPU register path;
- general DMA, the WRAM data port, and fast-ROM selection;
- directional CPU/APU ports, an IPL upload handshake, and synchronized
  SPC700/32 kHz timelines; and
- an emulation/native-mode 65C816 interpreter subset with interrupt entry/RTI.

It boots the HiROM `Final Fantasy III` test image through its title screen, but
it is not yet a playable core. Unsupported CPU opcodes return an error instead
of silently behaving like NOP. Sprites, windows, color math, the remaining
background modes, HDMA, controllers, cartridge coprocessors, SRAM, the
SPC700/DSP engines, and DRAM-refresh stall insertion remain future milestones.
The host-facing
`Beamicom.Host.System` adapter should be added once the core can produce a real
frame and audio boundary.

Widths follow the 65C816 M and X flags. Bus accesses advance SNES master clocks
using their mapped 6-, 8-, or 12-clock cost, while internal CPU cycles take six
master clocks. CPU timing is accumulated between device-event boundaries and
APU work is batched at scanline/port boundaries. WRAM, VRAM, CGRAM, and OAM use
persistent fixed arrays. The PPU decodes planar data once per tile row and
reuses a completed RGB frame when final visual state is unchanged.

## Tests

```sh
mix test
```

Run the reproducible native FF3 title-loop benchmark (180 warmup frames, then a
360-frame window with a 60 FPS minimum):

```sh
mix beamicom.snes.benchmark
```

An explicit ROM path and workload can also be supplied:

```sh
mix beamicom.snes.benchmark /path/to/game.sfc --warmup 180 --frames 360 --minimum-fps 60.0
```

## Bring-up order

1. Complete and validate all 256 65C816 opcodes, addressing modes, vectors,
   decimal arithmetic, and emulation/native-mode edge cases.
2. Complete the remaining CPU I/O registers, multiplication/division, WRAM
   port, DRAM refresh, DMA, and HDMA on the established master-clock timeline.
3. Extend the native PPU through OBJ, windows, color math, and Modes 2-7;
   implement the SPC700 and S-DSP behind the established ports and independent
   1.024 MHz/32 kHz timing accumulators.
4. Expose real frame/audio slices through `Beamicom.Host.System` and register
   the core in clients.
5. Add optional Nx renderers at the same frame/block boundary used by the NES
   and Game Boy cores, keeping CPU-visible timing in native control state.

## References

- [65C816 opcode reference](https://6502.org/tutorials/65c816opcodes.html)
- [WDC W65C816S data sheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
