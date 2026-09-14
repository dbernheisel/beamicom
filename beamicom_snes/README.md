# Beamicom SNES

A Super NES core written in Elixir, with a native implementation and optional
Nx/EXLA PPU acceleration. The implementation currently includes:

- copier-header detection and LoROM, HiROM, and ExHiROM header selection;
- SNES header metadata and mirrored ROM addressing, including non-power-of-two
  images such as 3 MiB cartridges;
- the CPU-visible WRAM, SRAM, MMIO, and cartridge ROM map with slow/fast access costs;
- an NTSC/PAL master-clock beam counter with NMI and H/V timer IRQs;
- native Mode 0, Mode 1, and Mode 7 rendering with OBJ, windows, color math,
  brightness, and scanline-varying state;
- general DMA, HDMA, the WRAM data port, and fast-ROM selection;
- directional CPU/APU ports, IPL upload, an SPC700 interpreter, S-DSP mixing,
  and synchronized 32 kHz stereo PCM output;
- an emulation/native-mode 65C816 interpreter with interrupt entry/RTI; and
- optional frame-wide Nx/EXLA renderers for the supported Mode 1 and Mode 7
  paths, with automatic native fallback.

It boots and renders the tested Final Fantasy II, Final Fantasy III, Super Mario
World, and Super Metroid scenes with active audio. It is not yet a complete or
cycle-perfect core: unsupported CPU operations return an error instead of
silently behaving like NOP, and controllers, the remaining background modes,
cartridge coprocessors, and further timing/DSP accuracy remain future work.

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

1. Complete and validate all 256 65C816 opcodes, addressing modes, vectors,
   decimal arithmetic, and emulation/native-mode edge cases.
2. Complete the remaining CPU I/O registers, multiplication/division, WRAM
   port, DRAM refresh, DMA, and HDMA on the established master-clock timeline.
3. Extend the native PPU through the remaining modes, mosaic, offset-per-tile,
   hires, and interlace details; continue improving S-DSP accuracy.
4. Complete controllers and host integration, then add cartridge coprocessors
   such as Cx4 and Super FX behind the cartridge boundary.
5. Expand Nx coverage while keeping CPU-visible timing in native control state.

## References

- [65C816 opcode reference](https://6502.org/tutorials/65c816opcodes.html)
- [WDC W65C816S data sheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
