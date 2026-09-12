# Resident MMC5 NES frame runner

For the subsequent copy-removal optimization, see [buffer-copy results](COPY_RESULTS.md).

`NxNes.Machine` runs Castlevania III from its reset vector with the complete PRG
and CHR ROM, RAM, mapper, PPU, APU, controller and CPU state held in Nx tensors.
The compiled frame loop performs CPU execution, device accesses, interrupt
handling, DMA, rendering and audio generation. It makes no host callbacks.
One host call supplies controller masks and advances to the next completed frame.

The existing `Beamicom.NES` production implementation remains native Elixir and
has no Nx/EXLA dependency. This runner lives in the isolated experiment project.
It is functional experimental integration, not yet a real-time replacement.

## Full branchless CPU and device follow-up

The generic CPU now evaluates every supported official and unofficial operation
as arithmetic candidates and selects register/write results by decoded operation
class. Both CPU batches and the fully timed device-boundary path use this
dispatcher. Addressing modes likewise compute safe candidates and select the
effective address, next PC and page-cross result. APU writes, PPU register
reads/writes and MMC5 register access use the same candidate-and-mask scheme.
The old conditional CPU step remains a differential oracle, and an all-opcode
queued-write test compares the two implementations directly.

The frame boundary donates the resident RAM, WRAM, framebuffer, audio buffer and
APU container so EXLA may reuse their buffers for same-shaped outputs. ROM stays
resident and immutable. Donation has to be targeted: donating the entire mutable
machine is rejected when a compiled frame does not consume and return every
marked field. MMC5 mapper state is mostly small scalars, so branchless selection
is the useful optimization there; broad donation would add little and is not
valid for unused fields.

The complete 902-frame cold-boot Castlevania III run remains exact: 8,296,332
instructions, 26,859,520 CPU cycles, 661,818 samples, every framebuffer and
palette byte, mapper/PPU/APU state, and PCM all match native Elixir. Under the
same sequential-thunk diagnostic as the prior full result:

| Measurement | Previous optimized | Branchless devices | Branchless scheduler, generic |
| --- | ---: | ---: | ---: |
| Total core time | 418.508 s | 313.582 s | **298.434 s** |
| Throughput | 2.155 FPS | 2.876 FPS | **3.022 FPS** |
| Mean frame | 463.978 ms | 347.652 ms | **330.858 ms** |
| Median frame | 457.154 ms | 342.319 ms | **325.796 ms** |
| p95 frame | 499.123 ms | 375.300 ms | **354.717 ms** |
| p99 frame | 540.620 ms | 400.175 ms | **369.970 ms** |
| Initial compilation | 33.618 s | 31.748 s | **13.330 s** |

The scheduler follow-up reduces time by another **4.83%** and raises throughput
by **5.08%** against the branchless-device result. Against the previous optimized
core, all branchless changes reduce time by **28.7%** and raise throughput by
**40.2%**. Native comparison work in the final run reached 78.27 FPS, leaving the
resident Nx core about 25.9 times slower.

The important correction was that the fully timed CPU path still called the old
opcode conditional tree even after batches became branchless. It now uses the
same branchless executor and a branchless addressing-mode resolver. The outer
batch-safety branch became a zero-iteration deadline: unsafe batches enter the
CPU loop with no available cycles and fall through to one timed instruction.
The guarded ROM block is now opt-in with `--block`; a matched 60-frame run found
the generic graph 2.5% faster because the full-state guard cost more than
specializing 5.9% of instructions.

The optimized generic HLO fell from 17.4 MB, 741 conditionals and 16,257 static
copy operations to 9.8 MB, 281 conditionals and 7,679 copies. These are graph
sites, not executed-copy counts. A fresh 60-snapshot runtime sample found copy
paths in 7 of 60 executor records, versus 23 of 57 in the earlier sample;
executor/dependency scheduling was the largest new category at 19 of 60.
Experiments that packed APU branch outputs or evaluated all PPU event candidates
reduced static copies but slowed execution, so they were reverted.
Runtime sample summary: [branchless generic profile](results/machine_profile_branchless_generic.json).

The machine retains its 64-entry RAM journal. The isolated branchless CPU is
fastest with eight entries, but changing the integrated journal cadence exposed
PPU frame-boundary differences during cold boot. The 64-entry cadence and
conservative specialized-block bound complete all 902 frames exactly.

Raw results: [branchless device/donation run](results/machine_bench_branchless_devices_sequential.json)
and [branchless scheduler run](results/machine_bench_branchless_scheduler_sequential.json).

## Run it

From `experiments/nx_nes`, with the project's Elixir/OTP versions:

```elixir
media = File.read!("../../beamicom/roms/castlevania3.nes")
{:ok, state} = NxNes.Machine.load(media)
run = NxNes.Machine.compile(state, media)
{state, instructions} = run.(state, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
:running = NxNes.Machine.status(state)
%{framebuffer: framebuffer, pcm: pcm, audio_samples: count} = NxNes.Machine.output(state)
# Feed state back to run; only controller masks and output cross the host boundary.
```

The optional `:entry` argument enables a guarded ROM-specialized block at the
observed hot loop. The measured default uses the faster generic interpreter and
internal CPU batching. The loader initializes from the iNES cartridge and reset state;
it does not replay a captured CPU trace or device event recording.

`output/1` returns the same native framebuffer structure that existing RGB/PNG
presentation code understands, plus signed 16-bit little-endian 44.1 kHz mono PCM.
It does not export ROM/RAM or otherwise round-trip emulator state to Elixir.
The application's production UI has not been switched to this experimental path.

## Implemented device integration

- MMC5 PRG modes, ROM/RAM windows, banked WRAM and upper-window RAM protection.
- MMC5 sprite/background CHR modes, ExRAM, nametable selection/fill, split control,
  multiplication registers and scanline IRQ status/acknowledgment.
- PPU register reads/writes, scroll/address latches, buffered data reads, palette
  mirroring, OAM, vblank, odd-frame timing, scanline rendering and frame publication.
- PPU timing before/after CPU memory access, NMI edge/pending state and status-read
  suppression, mapper/APU IRQ polling, and OAM DMA copy/stall/parity.
- Live APU writes/status, base channels, MMC5 audio, PCM filtering and frame output.
- Resident controller strobe/serial reads for both ports.

The native implementation is the differential timing/behavior reference. This
port inherits that implementation's abstractions (including scanline rendering
and its lazy APU IRQ polling), rather than claiming additional hardware accuracy.

## Optimization boundaries

The CPU's arithmetic dispatcher operates on a smaller CPU/memory container.
Device reads occur once before arithmetic and device writes once afterward,
inside Nx. This avoids duplicating the device graphs under every opcode branch.
An initial direct nesting took several minutes to compile; separating the graphs
made the first working frame runner compile in about 17 seconds.

The frame scheduler advances ordinary instructions in resident CPU batches only
while no PPU event or observable interrupt can intervene. A device read/write
barrier or insufficient whole-instruction budget returns control to the fully
timed instruction path **inside the same compiled call**. RAM/mapper/device work
never relies on a native CPU fallback.

A specialized block is additionally guarded by its current mapped ROM bytes and
ROM-backed windows. A self-loop can execute multiple whole iterations before the
next PPU event. Mapping changes, partial blocks, pending interrupts and unusual
code take the generic tensor path. The original native emulator is a separate
application fallback for machines without XLA.

Audio can accumulate while its IRQ is inhibited, but synchronizes before audio
register access and at frame output. When frame IRQ is enabled, the native bus's
100-cycle lazy flush boundary is retained. These batches run the existing Nx
block APU kernel; no native audio loop is used.

## Validation and measurements

The complete experiment suite passes **34 tests**, including the existing
CPU, PPU and APU regressions and new MMC5 register/memory tests plus a full
resident frame test exercising DMA, NMI and guarded instruction batches.

The **902-frame cold-boot run completed with every comparison passing**:
8,296,332 instructions, 26,859,520 CPU cycles and 661,818 audio samples. This is
approximately 15 seconds of emulated NTSC time, with no controller input.

| Measurement | Result |
| --- | ---: |
| Resident Nx execution, sequential diagnostic | 1269.502 s / **0.711 FPS** |
| Native comparison loop in this run | 13.511 s / 66.76 FPS |
| Median Nx frame | 1349.361 ms |
| Initial compilation, excluded | 86.499 s |
| Specialized instructions | 572,358 / 8,296,332 (6.90%) |

The original standalone native benchmark was about 83.7 FPS. The native number
above measures this validation script's comparison loop, which also ran on a
shared desktop alongside the Nx workload; it is not a replacement for that
standalone native benchmark. The full Nx core is **not close to real time**.
The earlier isolated block/PPU/APU speedups did not translate into a full-core win.

The PCM SHA-256 is
`0aaab7e4ee5edbab8579849e9433602144130e5bec1d348660fa07e7730d3a2b`,
exactly matching the original 902-frame native baseline. Every frame's pixels
and palette also matched native byte-for-byte. The new video hash concatenates
raw pixels and palette bytes, so its serialization differs from the original
benchmark's Erlang framebuffer-struct hash.

Raw timings, totals and hashes: `results/machine_bench_sequential.json`.
Core implementation checkpoint: `b8fe2d9`. Default XLA configuration was retained;
the sequential override was process-local for this diagnostic run. No 902-frame
GPU or default-scheduling throughput claim is made.

Some regression compilation and a separate profiling process ran concurrently
with early/middle portions of this validation; timing remains diagnostic. The
emulated workload and frame-by-frame oracle checks were unchanged throughout.

`machine_bench.exs` runs the full ROM and separately advances native Elixir as a
comparison oracle after each measured Nx frame. The native core supplies no
state or events to Nx during execution. Checks include CPU/NMI/IRQ state,
RAM/WRAM, mapper registers and banks, PPU control/VRAM/OAM/ExRAM, every framebuffer
pixel and palette byte, audio sample counts, and PCM. APU integer state is exact;
floating state uses an absolute tolerance of 1e-9. The standalone native
project also passes its own nestest test without the Nx experiment dependencies.

Initial upload, compilation, native-reference execution and comparison exports
are excluded from Nx frame timing. Each timed call synchronizes its result.
The validation run uses a shared, unpinned desktop; it is a baseline for further
profiling, not a controlled hardware benchmark.

```sh
MIX_ENV=prod mix run machine_bench.exs --frames 902 --output results/machine_bench.json
```

The optional process-local scheduling diagnostic from `NX_APU_PROFILE.md`:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run machine_bench.exs \
  --frames 902 --output results/machine_bench_sequential.json
```

The script writes progress, PNG frames, a WAV and a resident-state checkpoint
under ignored `tmp/machine/`. The ROM and those captures are not committed.
`--start-frame N` injects Start for three frames in both implementations.

## Full-machine runtime sample

A separate warmed process advanced from a live-game checkpoint under GDB,
using the sequential thunk diagnostic. Across 60 all-thread snapshots, 57 stacks
contained executor activity:

| Observed executor path | Stack records |
| --- | ---: |
| Tensor copies (`CopyThunk`, including its `memcpy` calls) | 23 |
| Generated computation kernels | 14 |
| Executor/dispatch | 13 |
| Thread synchronization | 3 |
| Other copies | 2 |
| Allocation/protection | 2 |

These are **stack counts, not CPU-time percentages**. Debugger pauses perturb
execution, and neither tensor-copy sizes nor total memory traffic were measured.
The evidence points to tensor copies and runtime dispatch as the next profiling
focus. Eigen worker activity is still visible: sequential thunk execution does
not disable all parallel kernel work.

Summary: `results/machine_profile_sequential.json`. To reproduce after generating
a checkpoint with `machine_bench.exs`:

```sh
NX_PROFILE_WORKLOAD=machine_profile.exs NX_PROFILE_PREFIX=machine \
  NX_PROFILE_COMPILE_TIMEOUT=240 APU_PROFILE_SEQUENTIAL=1 \
  APU_PROFILE_LABEL=_sequential APU_SAMPLES=60 python3 sample_apu.py
```

The sampler launches its own inferior; it does not attach to the live validation
run or change system tracing permissions. Raw stacks stay in ignored `tmp/`.

## Limits and next work

The loader currently accepts MMC5 cartridges with CHR-ROM. Other mappers and
CHR-RAM need their own integrated device paths. Enabling DMC stops explicitly;
DMC playback/DMA and Sunsoft 5B are not implemented here. This is not a claim of
complete NES cartridge compatibility. A failed runner reports a sticky stop
reason, and `output/1` refuses to publish a failed frame.

Only one discovered block is compiled per runner; arbitrary ROM discovery and a
multi-block cache are not implemented. Whole-core performance is still far below
native Elixir. Further profiling should focus on the full scheduler, generic CPU
batches and device-boundary cost using this live workload, while retaining
frame-by-frame correctness checks.
