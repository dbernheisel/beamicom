# MMC5 graphics and audio experiment

This extends the CPU probe to the actual PPU and APU work. The production cores
remain unchanged. The kernels run on EXLA's **CPU** backend; this is not GPU work.

## What is implemented

`NxNes.PPU.render/2` implements CHR-ROM scanline rendering with MMC5 nametable
sources (both CIRAM pages, ExRAM and fill), background and sprite CHR bank sets,
extended attributes, vertical split, fine scrolling, 8x8/8x16 sprites, both flips,
OAM priority, the eight-sprite limit, overflow, sprite-zero hit, clipping and
scroll advancement. It returns palette-address pixels, status and scroll results.
CHR-ROM stays resident and can be shared across a batch of scanlines.

This is not the entire CPU-facing PPU: register accesses, DMA, IRQ/NMI scheduling,
palette writes and framebuffer publication are still handled by the reference
emulator. MMC2/4 latches, CHR-RAM and unlimited sprites are outside this probe.

`NxNes.APU.advance/2` implements the base NES pulse/triangle/noise channels and
MMC5 pulse/PCM expansion: timer/sequence advancement, noise LFSR, envelopes,
length and linear counters, sweep, frame IRQ, both sequencers, nonlinear mixing,
64-bit floating-point filters, rounding and signed 16-bit PCM output.

`NxNes.APU.run/2` advances continuous time, retaining device state on EXLA between
calls. It returns only the output buffer/count plus resident state and unconsumed
cycles. A full 1,024-sample buffer yields instead of silently truncating output.
`NxNes.PackedAPU.run/2` evaluates the same equations with two resident state
buffers, one integer and one floating-point, as an alternative to scalar tensors.

Audio register writes and DMC/Sunsoft 5B are not ported. Unsupported audio
devices are explicitly rejected; the captured Castlevania workload uses no DMC.
Continuous audio tests have no intervening register writes and are not presented
as a replay of the game's soundtrack.

## Real-workload validation and measurements

`capture_devices.exs` runs the original 902-frame cold-boot workload and captures
states at frames 0, 60, 180, 300, 420, 540, 660, 780 and 900. In an isolated VM it
inserts observation hooks into in-memory copies of the original modules; it does
not edit any production source. Local captures in `tmp/` contain ROM-derived
state and are ignored by Git.

The dataset has **2,160 scanlines and 9,235 APU event steps**, of which 8,204 have
MMC5 audio active. Device replay checks pixels, sprite flags, scroll results,
PCM, sample counts and all represented integer audio state exactly. Floating
audio state is compared with a 1e-12 tolerance. All checks pass. The sample has
normal MMC5 graphics mode only; synthetic differential tests separately exercise
extended attributes, both split directions, fill/ExRAM sources, sprite flips,
scroll wrap, sequencer boundaries, both noise modes and continued resident state.

The PPU benchmark compares the same captured scanlines against public experiment
copies of the original private rendering functions. CHR-ROM is uploaded once.
Resident timings include output synchronization; upload timings additionally
include transferring prepacked inputs. Neither includes packing Elixir state
into tensors. Batches preserve every scanline's captured state, not one final
register snapshot for a whole frame.

Frame-sized batches are faster than the existing renderer; individual scanline
calls are slower. See `results/devices_probe.json` for raw repeated timings and
compilation costs. These are **device replay speedups, not full-game FPS gains**.

Median times for the complete captured dataset:

| Workload | Existing Elixir | Nx resident | Comparison |
| --- | ---: | ---: | --- |
| 2,160 PPU lines, one line/call | 35.65 ms | 131.19 ms | 3.68x slower |
| Same lines, 240 lines/call | 35.65 ms | 12.73 ms | 2.80x faster |
| Same frame batches, including prepacked input upload | 35.65 ms | 13.16 ms | 2.71x faster |
| 9,235 independent APU event states, 256/call | 15.08 ms | 12.61 ms | 1.20x faster |

The APU event batch is a replay of **independent input states**, not parallel
advancement of one audio timeline. Its small gain does not carry over to the
sequential resident test below. Including prepacked state uploads raises that
APU event replay to 22.17 ms, slower than the reference.

For continuous audio, `apu_continuous.exs` starts from a real active Castlevania
APU state and advances 64 intervals of 29,830 CPU cycles with no register writes.
Both implementations export PCM. They produce identical complete PCM streams
and matching final hardware state. Five repeated timings are saved in
`results/apu_continuous.json`. The current Nx implementation is slower than the
existing Elixir APU; packing the state does not improve that result.

The five-run median is **45.79 ms** for the existing APU, **216.53 ms** for Nx
scalar state (4.73x slower), and **289.59 ms** for packed state (6.32x slower).
These include PCM export, preserve the complete sample stream and end state,
and exclude compilation (approximately 193 ms scalar / 286 ms packed).
The separate `continuous_apu` section in the device replay artifact is an earlier
three-run control returning Elixir sample lists; use `apu_continuous.json` for the
comparison with equivalent PCM export on both sides.

The optimized-XLA inspection of the initial audio loop showed many scalar
fusion kernels and copies rather than one tight scalar interpreter loop, with
only about 18 KiB of assigned buffers. This points toward scalar execution
overhead rather than large ROM/RAM transfers as a likely issue, not proof of a
single cause. Replacing composite conditionals with element selections and
using an exact XOR-linear LFSR jump lookup did not reverse the result. The jump
table reconstructs any 15-bit state from three five-bit chunks and supports both
noise feedback taps. Tests compare it to the reference bit-by-bit evolution.

An additional run with `--xla_cpu_use_thunk_runtime=false` reported that the
option is no longer supported; it did **not** test a different runtime.
`results/apu_legacy_runtime.json` records that unsuccessful configuration attempt.
No such flag is enabled in project configuration.

## Nx runtime profiling follow-up

[The runtime profile](NX_APU_PROFILE.md) now identifies concurrent dependency
scheduling as the main measured Nx APU bottleneck. A scheduling-only diagnostic
override reduces scalar Nx time from 211.2 ms to 80.6 ms with matching output.
This provides direct evidence beyond the native-C comparison below.

## Native CPU APU control

`native/apu.c` now implements one continuous 2A03/MMC5 event loop as an
experimental C NIF. It preserves the reference scheduling, channels, envelopes,
sweep, noise LFSR, mixer tables, filters, and PCM rounding. It uses no fast math
or fused multiply-add contraction. State is an immutable 896-byte binary passed
between calls; the NIF makes a local copy, advances it, and returns new state,
little-endian PCM, and any cycles remaining after the 1024-sample buffer fills.
The call runs on a dirty CPU scheduler and accepts at most 1,000,000 cycles.

This is a native control experiment, **not an EXLA custom call or a full-game
integration**. It does not keep the complete machine in Nx. Like the continuous
Nx comparison, it excludes DMC, Sunsoft 5B, and register writes inside an interval.
Initial state packing and final correctness checks are outside the timed region;
per-call state copies, scheduling, allocation, and PCM export are included.

`results/apu_native.json` records seven rounds with rotating implementation order,
after compiling and warming every variant. Each measurement advances 64 intervals
of 29,830 CPU cycles (about 1.067 seconds of audio).

| Implementation | Median time | Relative to native |
| --- | ---: | ---: |
| Existing Elixir APU | 57.173 ms | 41.25x slower |
| Nx/EXLA scalar state | 209.694 ms | 151.29x slower |
| Nx/EXLA packed state | 286.010 ms | 206.36x slower |
| Native C loop | 1.386 ms | 1.00x |

Desktop noise remains visible in the raw timings (including one 157 ms Elixir
outlier). These are APU workload ratios, not whole-emulator speedups.

The complete continuous PCM stream matches byte-for-byte, SHA-256
`3364b2f92e1f3b79d2ebd9fc769b2bfbb552fdb488fd0533848afd5e9603dc7b`.
All integer fields match exactly and floating fields agree within 1e-12.
Additionally, all 9,235 captured Castlevania APU events pass independent PCM and
state comparison, covering states changed by actual game register writes.
The experiment suite passes 11 tests, including native sequencer boundaries,
both noise modes, MMC5 enabled/disabled, continued state, buffer exhaustion,
immutable checkpoints, and malformed native arguments. The two native tests also
pass with the C undefined-behavior sanitizer enabled.

The current optimized XLA graph has 110 fusion operations and 155 copy operations,
with 63.5 KiB of assigned buffers, largely lookup constants. These are static
compiler counts, not measured runtime percentages. Linux `perf` sampling was
unavailable (`perf_event_paranoid=4`); the machine's security settings were not
changed. The native result strongly supports poor lowering/execution of this
sequential scalar workload as the cause of the Nx slowdown, but does not isolate
dispatch, redundant arithmetic, and scalar copies individually.

A useful next integration experiment is a native APU call at existing flush and
register-write boundaries, or an EXLA custom call for the resident-machine design.
Either requires a new full-game benchmark: the reference already batches some
APU work, and input/state conversion at frequent boundaries may reduce this gain.

## Integration implications

The next useful integration target is the PPU renderer. To obtain the batching
gain in a live emulator, CPU-visible sprite status and IRQ/NMI events must still
be computed at their correct times. Collecting a frame and delaying those effects
would break games. The intended complete resident scheduler could batch pixel
work while maintaining those interactions inside compiled execution.

For now there is no measured reason to replace the existing APU with this Nx
implementation. The resident API and differential kernels remain useful for
further compiler/layout experiments, but the CPU-loop result alone was not a
reliable predictor for either graphics or audio.

## Reproduce

From this experiment directory, using the repository's Elixir/OTP versions:

```sh
MIX_ENV=prod mix run capture_devices.exs ../../beamicom/roms/castlevania3.nes > results/device_capture.txt
MIX_ENV=prod mix run devices_probe.exs > results/devices_progress.txt
MIX_ENV=prod mix run build_native.exs
MIX_ENV=prod mix run apu_continuous.exs
mix test
```

Run timing commands sequentially. The capture run is instrumented and is not a
performance measurement. These measurements are on a shared desktop without
fixed CPU clocks; retain the repeated timings rather than treating a single run
as a universal speed prediction.

The native library and generated schema live under ignored `tmp/`; rebuild on a
fresh checkout before running the audio comparison or tests. A C compiler and the
installed Erlang NIF headers are required. For the native sanitizer check:

```sh
NATIVE_SANITIZE=1 MIX_ENV=prod mix run build_native.exs
MIX_ENV=test mix test test/native_apu_test.exs
MIX_ENV=prod mix run build_native.exs
```

The last command restores the optimized library used for timings.
