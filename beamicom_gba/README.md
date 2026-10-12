# Beamicom GBA

`beamicom_gba` is a new deterministic Game Boy Advance core written in
Elixir. Scalar Elixir is the correctness path; optional Nx/EXLA renderers can
accelerate fixed-shape work without replacing CPU, bus, DMA, timer, or
interrupt semantics.

The production CPU path uses the scalar ARM/Thumb interpreter with narrowly
recognized semantic loop accelerators. The optional decoded-block executor and
the unaccelerated scalar interpreter remain available for performance and
differential testing.

## Current milestone

The initial vertical slice provides:

- validated GBA cartridge headers and immutable 32 MiB ROM-window mapping;
- page-chunked EWRAM, IWRAM, palette RAM, VRAM, and OAM;
- a serializable master-cycle scheduler with deterministic same-cycle ordering;
- an ARM7TDMI interpreter seed covering common ARM and Thumb arithmetic,
  branches, loads/stores, stack operations, register-list transfers, status
  register writes, processor-mode banking, and IRQ entry/return;
- four DMA channels with immediate, VBlank, HBlank, and Direct Sound FIFO
  triggers;
- four 16-bit timers with globally phased prescalers, count-up chaining,
  overflow reloads, and IRQ requests;
- DISPSTAT, IE, IF, and IME interrupt behavior plus BIOS `Halt` wake-up;
- clean-room HLE for BIOS reset, interrupt-wait, signed arithmetic, copy, LZ77,
  sound-bias, and MIDI-frequency services exercised by compatibility smoke
  tests;
- GBA byte-write behavior for palette RAM, VRAM, and OAM;
- the 1,232-cycle scanline and 280,896-cycle frame cadence;
- scalar and exact-parity Nx rendering for tiled modes 0 and 1, affine
  backgrounds and objects, bitmap mode 3, scanline register changes, layer
  priority, alpha blending, and brightness effects;
- four legacy PSG voices with sweep, envelopes, lengths, banked wave RAM, and
  stereo routing, plus timer-driven Direct Sound A/B FIFOs and DMA1/2 refill;
- deterministic 44.1 kHz signed PCM generation from the combined six-channel
  mix;
- versioned, bounded save-state serialization and self-contained PNG snapshots
  that resume with exact CPU, bus, video-timing, backup, and audio state;
- the `Beamicom.Host.System` boundary with 240x160 RGB24 frames, keypad input,
  and stereo audio chunks.

This milestone is intended for diagnostic and homebrew bring-up. Display modes
2, 4, and 5, windows, mosaic, complete BIOS coverage, and cycle-exact DMA
remain to be implemented before broad software
compatibility is meaningful.
Unsupported CPU and BIOS operations stop with explicit errors instead of
silently approximating behavior.

## Development

```sh
mix deps.get
mix test
mix gba.bench --frames 30
mix gba.bench --executor scalar --no-fast-loops --frames 30
mix gba.bench --executor decoded-blocks --frames 30
```

The benchmark uses Scenic's 800,000-word emulator heap by default. Override it
with `--heap-words` or `--binary-heap-words` when measuring allocation and GC
tradeoffs.

Set `BEAMICOM_NX=1` before compilation to select the Nx PPU backend:

```sh
BEAMICOM_NX=1 mix compile --force
BEAMICOM_NX=1 mix test
```

The scalar renderer remains the reference oracle. Nx changes are accepted only
when they produce byte-identical frame output.

The scalar CPU executor with semantic loop acceleration is the default used by
the host and Scenic. Pass `cpu_executor: :scalar, fast_loops: false` to
`Beamicom.GBA.Machine.load/2` when debugging or comparing every individual
instruction against the reference path.

## BIOS and ROMs

Skip-boot state is the default for controlled diagnostics. Pass
`skip_boot: false` with a legally obtained 16 KiB `:bios` binary to execute
from address zero. This project does not distribute Nintendo firmware or ROMs.
