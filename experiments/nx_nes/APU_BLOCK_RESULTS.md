# Timestamped Nx audio blocks

The block approach improves the measured Nx APU workload. On a replay of the full
15-second Castlevania III capture, default XLA takes **356.695 ms** with block
waveform evaluation, versus **5,585.197 ms** with the matched scalar Nx loop and
**1,013.117 ms** with the Elixir reference. That is **15.66x faster than scalar Nx**
and **2.84x faster than Elixir** on this isolated audio workload.

## What changed

`BlockAPU.run/4` accepts resident APU state, a tensor of timestamped operations,
the operation count, and the number of CPU cycles to render. It returns updated
resident state, PCM, sample count, unconsumed cycles, and consumed operation count.
Operations are base/MMC5 register writes plus a tagged $4015 status read that
preserves frame-IRQ clearing. DMC/5B operations are rejected by the host packer.

The kernel splits time at writes/reads, base sequencer events, and MMC5 sequencer
events. Between these boundaries, channel configuration is stable. It computes
up to **128 sample positions together** using tensor operations for channel
phases, pulse/triangle values, exact noise LFSR jumps, and mixing. It carries only
the small sample-clock state through one loop and the filter history through
another; the complete APU state is updated once per segment rather than once per
sample. Filters retain the reference recurrence and operation order.

Noise jumps use binary powers of the exact XOR-linear transition, supporting
both feedback taps and all tested 15-bit states. Writes at an audio sample's
cycle occur after advancing to that cycle, matching the existing emulator's
flush-before-write ordering. Multiple operations at one timestamp retain order.

`ScalarEventAPU.run/4` is the matched control: it accepts the same timestamp tensor
and produces the same outputs, but runs the original `APU.advance/2` sample by
sample. This includes operation-dispatch overhead missing from the older
no-register-write continuous benchmark, so its timing is a new baseline.

## Workload and results

The instrumented capture runs 902 video frames from cold boot without input and
records 26,859,513 APU CPU cycles, **1,516 operations**, and **661,818 audio samples**.
Replay uses 901 calls covering up to 29,830 cycles each; the last is partial.
There are at most 12 operations in one call. Input tensors currently reserve
128 operation slots, independently of the 128-sample internal vector width.

Five timed repetitions rotate implementation order, following compilation and
an initial correctness/warmup pass. Initial state and operation tensors are
prepared and uploaded before timing. Timing includes PCM export and per-call
output count checks. Compilation, capture, event production/upload, CPU, PPU,
and audio-device playback are excluded. State stays on EXLA between calls.

| Implementation | Default XLA median | Sequential diagnostic median |
| --- | ---: | ---: |
| Elixir reference | 1,013.117 ms | 951.291 ms |
| Scalar Nx with timestamped operations | 5,585.197 ms | 1,947.987 ms |
| Block Nx with timestamped operations | **356.695 ms** | **259.829 ms** |

The diagnostic column uses the same explicit process-local scheduling override
from `NX_APU_PROFILE.md`. The block algorithm itself improves performance with
normal configuration. Under the override it is **7.50x faster than scalar Nx**;
the override removes another **27.2%** from default block time. No override is
enabled in application configuration. Compilation took approximately 0.52–0.57
seconds per kernel and is excluded from the table. This shared desktop has
unpinned clocks and visible timing variation; raw repetitions are retained.

## Accuracy

Both Nx variants match the Elixir timestamped replay PCM byte-for-byte for the
complete capture. That replay also matches **every PCM byte from the original
full-game run**, not merely a constant-note or independently seeded-state test.
The audio SHA-256 is:

`0aaab7e4ee5edbab8579849e9433602144130e5bec1d348660fa07e7730d3a2b`

All final integer fields match exactly and floating fields agree within 1e-12
against both the reference replay and the original full-game APU capture. The experiment suite passes **15 tests**, including
base/MMC5 register values, status reads, sequencer and sample boundaries,
same-cycle operation ordering, resident continuation, both noise modes, long
noise jumps, and unsupported-input rejection.

The real capture enables MMC5 audio through $5010 but does not program the MMC5
pulse channels or PCM DAC. Synthetic tests exercise those additional writes and
active expansion-channel states. These checks establish parity with the current
emulator; they do not establish new hardware accuracy or DMC support.

## Integration scope

This is a complete captured audio-timeline replay, with writes applied inside Nx.
It is not yet a live emulator integration or a full-machine Nx core. A live path
must produce these events and preserve CPU-visible IRQ/status/memory interactions
at their proper times. The status-read marker currently applies its state effect;
the replay API does not return read values or a cycle-by-cycle IRQ trace to a CPU.
Input-event production/upload and that coupling need their own benchmark before
claiming an end-to-end game speedup.

The production emulator core is unchanged. Changes to shared APU helpers are
confined to this isolated Nx experiment; the earlier scalar tests still pass.

## Reproduce

From `experiments/nx_nes`, with the project's Elixir/OTP versions:

```sh
MIX_ENV=prod mix run capture_apu_events.exs ../../beamicom/roms/castlevania3.nes
MIX_ENV=prod mix run apu_blocks.exs
MIX_ENV=test mix test
```

For the optional scheduling control, build the profiler's diagnostic library
with `python3 build_scheduler_probe.py`, then run:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run apu_blocks.exs results/apu_blocks_sequential.json
```

The capture and PCM stay under ignored `tmp/`. Results are recorded in
`results/apu_blocks.json` and `results/apu_blocks_sequential.json`.
