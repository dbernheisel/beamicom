# Beamicom SNES

A Super NES core written in Elixir, with a native implementation and optional
Nx/EXLA PPU acceleration. The implementation currently includes:

- copier-header detection and LoROM, HiROM, and ExHiROM header selection;
- SNES header metadata and mirrored ROM addressing, including non-power-of-two
  images such as 3 MiB cartridges;
- the CPU-visible WRAM, SRAM, MMIO, and cartridge ROM map with slow/fast access costs;
- an NTSC/PAL master-clock beam counter with NMI and H/V timer IRQs;
- native rendering paths for modes 0-7, with modes 2-6 still approximate, plus
  OBJ, windows, color math, brightness, and scanline-varying state;
- general DMA, HDMA, the WRAM data port, and fast-ROM selection;
- directional CPU/APU ports, native SPC700 IPL upload/launch, S-DSP mixing,
  and synchronized 32 kHz stereo PCM output;
- partial Capcom Cx4 support with its cartridge RAM/register window,
  ROM-to-RAM transfers, self-test responses, composite OAM generation,
  scale/rotate conversion, scalar math, and trapezoid clipping;
- an emulation/native-mode 65C816 interpreter with interrupt entry/RTI; and
- optional frame-wide Nx/EXLA renderers for the supported Mode 1 and Mode 7
  paths, with automatic native fallback.

It boots and renders the tested Final Fantasy II, Final Fantasy III, Super Mario
World, and Super Metroid scenes with active audio. It is not yet a complete or
cycle-perfect core: all 256 CPU opcode bytes dispatch, but addressing/timing
  edge cases, modes 2-6, remaining Cx4 graphics commands, other cartridge
  coprocessors, and further PPU/DSP accuracy remain future work. See the detailed
[implementation status matrix](IMPLEMENTATION_STATUS.md).

Widths follow the 65C816 M and X flags. Bus accesses advance SNES master clocks
using their mapped 6-, 8-, or 12-clock cost, while internal CPU cycles take six
master clocks. CPU timing is accumulated between device-event boundaries and
APU work is batched at port/frame boundaries and DSP output is split at
timestamped register writes. WRAM, VRAM, CGRAM, and OAM use persistent fixed
arrays. The PPU decodes planar data once per tile row and reuses a completed RGB
frame when final visual state is unchanged. Stable direct-page NMI polling loops
are fast-forwarded only within a scanline and only while H/HV IRQs are disabled.

## Tests

```sh
mix test
```

Run the default native FF3 benchmark:

```sh
mix beamicom.snes.benchmark
```

Select the optimized renderer explicitly for the 60 FPS E2E gate:

```sh
mix beamicom.snes.benchmark "roms/Final Fantasy III.sfc" \
  --renderer nx --warmup 1700 --frames 240 --minimum-fps 60.0
```

## Bring-up order

1. Validate all 256 65C816 opcodes, addressing modes, vectors, and
   emulation/native-mode edge cases with processor conformance ROMs.
2. Complete the remaining CPU I/O registers, multiplication/division, WRAM
   port, DRAM refresh, DMA, and HDMA on the established master-clock timeline.
3. Extend the native PPU through the remaining modes, mosaic, offset-per-tile,
   hires, and interlace details; continue improving S-DSP accuracy.
4. Complete the Cx4 graphics commands, then add Super FX and later cartridge
   coprocessors behind the cartridge boundary.
5. Expand Nx coverage while keeping CPU-visible timing in native control state.

## References

- [65C816 opcode reference](https://6502.org/tutorials/65c816opcodes.html)
- [WDC W65C816S data sheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
