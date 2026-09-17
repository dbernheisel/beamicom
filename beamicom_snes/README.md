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
- directional CPU/APU ports, native SPC700 IPL upload/launch, a single
  phase-authoritative S-DSP voice/echo pipeline, and synchronized 32 kHz
  stereo PCM output;
- versioned, self-contained save-state PNGs with a visible data border and an
  exact-transfer ROM trailer;
- partial Capcom Cx4 support with its cartridge RAM/register window,
  ROM-to-RAM transfers, self-test responses, composite OAM generation,
  scale/rotate conversion, scalar math, and trapezoid clipping;
- partial DSP-1/1A/1B support with mapper-specific ports, scalar and vector
  math, retained attitude matrices, fixed-point projection/target commands,
  and hardware-style streamed Mode 7 raster matrices;
- an emulation/native-mode 65C816 interpreter with interrupt entry/RTI;
- optional frame-wide Nx/EXLA renderers for the supported Mode 1 and Mode 7
  paths, with automatic native fallback; and
- runtime-selectable Nx ports of Blargg's SNES NTSC composite, S-Video, RGB,
  and monochrome presentation filters.

It boots and renders the tested Final Fantasy II, Final Fantasy III, Super Mario
World, and Super Metroid scenes with active audio. It is not yet a complete or
cycle-perfect core: all 256 CPU opcode bytes dispatch, but addressing/timing
  edge cases, modes 2-6, remaining coprocessor commands, and further PPU/DSP
  accuracy remain future work. See the detailed
[implementation status matrix](IMPLEMENTATION_STATUS.md).

Widths follow the 65C816 M and X flags. Bus accesses advance SNES master clocks
using their mapped 6-, 8-, or 12-clock cost, while internal CPU cycles take six
master clocks. CPU timing is accumulated between device-event boundaries and
APU work is batched at port/frame boundaries and DSP output is split at
timestamped register writes. WRAM, VRAM, CGRAM, and OAM use persistent fixed
arrays. The SPC700 and S-DSP share one atomics-backed 64 KiB APU RAM owned by
the machine; save states turn it into an immutable binary and restore a fresh
buffer. The PPU decodes planar data once per tile row and reuses a completed RGB
frame when final visual state is unchanged. Stable direct-page NMI polling loops
are fast-forwarded only within a scanline and only while H/HV IRQs are disabled.

Scenic and the benchmark enable one-job-deep presentation pipelines. An
immutable PPU snapshot renders alongside the following emulated frame, while
SPC700 execution remains synchronous. Eligible DSP spans may run alongside the
main CPU, but echo, noise, and pitch-modulation workloads stay on the
authoritative phase pipeline. Jobs are joined before their state can affect the
next device batch, preserving event order at the cost of one frame of host-side
audio/video latency. Other callers can opt in with
`Machine.load(media, render_pipeline: true, async_dsp: true)`. Pass
`apu_renderer: Beamicom.SNES.Nx.DSPRenderer`; it remains accepted for caller and
save-state compatibility, but authentic DSP synthesis currently stays on the
native phase pipeline. This avoids crossing BRR, echo-RAM, key, and live-register
boundaries with a compiled batch whose state transition is not yet equivalent.

The Blargg filter can be selected per machine without changing the configured
PPU composition backend:

```elixir
options = Beamicom.SNES.Nx.video_options(:composite)
{:ok, machine} = Beamicom.SNES.Machine.load(rom, options)
```

The presets are `:composite`, `:svideo`, `:rgb`, and `:monochrome`. Setup
overrides such as `hue: 0.1`, `artifacts: -0.25`, or `merge_fields: false` can
be passed as the second argument to `video_options/2`. The Nx blitter expands
each 256-pixel source row to 602 RGB24 pixels; square-pixel hosts should double
the scanlines.

## Save states

SNES states use the same share-image format as the other Beamicom cores: the
current 256×224 frame is enlarged and surrounded by a lossless dot-code border
containing the compressed machine state. The immutable ROM is stored after PNG
IEND and verified by size and SHA-256 when loaded. If a service removes the
trailer, the loader can find a matching `.sfc` or `.smc` in supplied folders.

```elixir
png = Beamicom.SNES.ShareImage.to_png(machine, frame.data)
{:ok, restored_machine} = Beamicom.SNES.ShareImage.load_image(png)
```

## Tests

```sh
mix test
```

Run the default native FF3 benchmark:

```sh
mix beamicom.snes.benchmark
```

Select the Nx PPU renderer explicitly for an end-to-end comparison:

```sh
mix beamicom.snes.benchmark "roms/Final Fantasy III.sfc" \
  --renderer nx --apu-renderer nx \
  --warmup 600 --frames 180
```

Add `--profile` for opt-in BEAM call counts and instrumented call times. Every
run reports p50/p95/max frame latency plus SHA-256 hashes for video, audio,
canonical hardware state, and the complete config-sensitive snapshot.

The 60 FPS target is not yet met on the development host. Compact BRR dependency
regions, allocation-reduced echo/voice mixing, and an aligned-sample schedule
preserve phase-27 bus closure, phase-29/30 echo writes, phase-31 BRR visibility,
and live-register wraparound; interrupted samples remain clock-by-clock. Current
180-frame measurements produced 52.30 FPS native and 54.23 FPS Nx-selected for
SMW after 300 warm-up frames, 45.14/46.61 FPS for FFIII after 600, and
37.29/37.27 FPS for Super Metroid after 600. Each native/Nx pair produced
identical video, audio, and canonical hardware-state hashes. PPU frame rendering
still runs concurrently with emulation.

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
