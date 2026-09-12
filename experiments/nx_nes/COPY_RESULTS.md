# Removing resident-core buffer copies

The frame runner now keeps immutable ROM handles out of its compiled results,
hoists unchanged state out of conditional/loop results, commits CPU byte writes
after instruction validation, and assembles the framebuffer outside the nested
CPU/device branches. All emulation arithmetic, memory writes, scanline assembly
and audio still execute in Nx. Elixir reattaches the existing immutable ROM
handles to the returned state; it does not read or mutate cartridge bytes.

## Executed copies

A process-local interposer counts actual XLA CPU `CopyThunk::Execute` calls by
source slice size. These are execution totals, not static instruction counts
or sampled CPU-time percentages. One warmup and five measured frames start
from the same saved checkpoint (CPU cycle 26,859,520, PPU frame counter 901).
Both versions match the native oracle on every measured frame.

| Copied buffer | Before: six frames | After: six frames |
| --- | ---: | ---: |
| 256 KiB PRG ROM | 498,782 | 0 |
| 128 KiB CHR ROM | 6 | 0 |
| 60 KiB framebuffer | 805,539 | 6 |
| 8 KiB WRAM | 3,787,893 | 357,662 |
| All CopyThunk bytes per frame | 36.398 GB | 1.085 GB |
| All CopyThunk calls per frame | 14,293,430 | 10,643,728 |

Total executed CopyThunk byte traffic falls **97.0%**. The framebuffer has
one copy per frame, preserving the immutable input tensor. ROM has none.
Copies remain, especially scalar state and smaller mutable buffers. This
counter does not measure copying inside generated kernels or host transfers.
The baseline counter overlapped regression tests; use the separate uninstrumented
runs for performance comparisons. Counts are independent of that contention.

Raw counts and scope: [copy_counts.json](results/copy_counts.json).

## Why these changes work

`StateGraph.prune/1` removes fields whose expression IDs are identical in every
conditional branch. It also bypasses unchanged loop outputs. This prevents
passthrough ROM and other state from acquiring conditional output buffers.
The pass is local to this experiment and depends on Nx 1.0.0 expression
internals; it targets the pure, bounded emulator graph, without hooks or callbacks.
`:prune_state` can disable this pass for diagnostics.

CPU dispatch returns up to three scalar address/value pairs instead of
speculatively modifying RAM. `CPU.step/2` first resolves whole-instruction
rollback and then commits accepted writes. Live CPU execution and interrupt
entry commit through the machine merge. The three entries cover BRK/interrupt
stack pushes, including stack wrap; native memory protection and MMIO barriers
remain in effect. ROM/code changes are still visible to subsequent instructions.

The full framebuffer no longer travels through every device conditional.
PPU events collect up to eight scanlines in a small tensor queue, and the outer
frame loop applies them to its separate framebuffer tensor. DMA can produce
multiple scanlines per instruction, so this is a queue rather than a single
pending row. Overflow stops explicitly. The standalone PPU path still supports
its original complete framebuffer state.

## Validation and performance

The full suite passes **34 tests**, including every supported opcode with
queued versus direct memory writes, deadline rollback, interrupt stack pushes,
and synthetic live frames covering DMA/NMI/rendering. Existing native CPU,
APU and PPU differential tests continue to pass.

A separate ten-frame comparison, without the copy counter or overlapping
benchmark/test processes, measures **1310.5 ms/frame before** and
**435.5 ms/frame after**: **3.01× faster**,
or 2.30 FPS. Compilation changes from 84.23 to
33.02 seconds. Both runs use the same live checkpoint and
verify every frame against native. Timings:
[before](results/copy_bench_baseline.json),
[after](results/copy_bench_optimized.json).

Timing uses the same optional sequential-thunk diagnostic as the previous
full-machine benchmark. It does not change the normal project configuration;
this remains a shared desktop with unpinned clocks. Native Elixir remains the
production fallback, and the Nx runner remains below real time.

The complete **902-frame cold-boot run** also passes, with the same
8,296,332 instructions, 26,859,520 cycles, 661,818 samples, and unchanged
video/audio SHA-256 hashes. Its core time is 418.508 seconds
(2.155 FPS), versus 1269.502 seconds before
(0.711 FPS). This full-run timing is diagnostic: follow-up compiler
experiments overlapped part of the run after frame 550. The ten-frame timings
above are the uncontended paired comparison. This result validates core commit
`d4dd73c`: [full-workload result](results/machine_bench_copy_optimized.json).

## Remaining ownership problem

The 1.085 GB/frame result is still excessive; it does **not** establish the
requested engine-owned, copy-free RAM architecture. The current API preserves
input tensor values and feeds a new logical state through nested control flow.
ROM handles are now reused, but that does not guarantee reuse of every mutable
buffer or its physical address across calls.

Follow-up diagnostics attributed large copies to the generic CPU loop and the
scanline queue inside PPU timing branches. Tested alternatives included
region-aware copy analysis, disabling loop invariant code motion, selected-region
scalar memory reads, transient/cleared queues, packed CPU state, guarded blocks
inside CPU batches, and an opaque register-materialization primitive. None
established copy-free RAM, and the unvalidated/performance-regressing core
alternatives were reverted. The materialization experiment copied only register
packets in a CPU custom call; it did not implement emulator arithmetic in C.

The next architectural acceptance test must establish exclusive memory ownership
and measured buffer reuse for compiled load/store/opcode operations before
integrating more whole-machine control flow. Existing Nx value semantics do not
guarantee in-place allocation reuse. Frame-level ownership/donation and copies
inside a compiled loop must be tested separately. The native Elixir fallback
remains unchanged.

Diagnostics: [follow-up measurements](results/copy_followup_diagnostics.json).
Set `NX_COPY_SITES=1` with the copy probe to write an additional
`<NX_COPY_REPORT>.sites.csv` file identifying executed copy operations of at least
1 KiB by HLO operation name. This extra instrumentation adds overhead.

## Pure Nx RAM journal follow-up

The CPU now keeps a 64-entry sparse write journal in the machine's existing Nx
map container. Internal 2 KiB RAM remains unchanged while a CPU batch executes;
reads select the newest matching journal entry, and the outer scheduler flushes
the journal only when it fills or the frame ends. Specialized ROM blocks use the
same read/write path. WRAM retains direct writes because journaling it increased
8 KiB copy traffic. This implementation is entirely Elixir/Nx and adds no native
extension or custom call.

Five checkpoint frames plus one warmup remain exact against the native core for
CPU, RAM, WRAM, mapper, PPU, framebuffer and PCM. The XLA CPU copy probe reports
**1.0494 GB/frame**, down from **1.0845 GB/frame** by **3.24%**. Probe timing is
**449.5 ms/frame (2.225 FPS)**, compared with the prior probe result of
**470.6 ms/frame (2.125 FPS)**. A 4,096-entry whole-frame journal was rejected:
linear lookup made it 0.65 FPS and raised traffic to 43.9 GB/frame. A 16-entry
RAM journal was also worse than 64 entries at 1.0639 GB/frame and 2.123 FPS.

Results: [timing](results/copy_bench_ram_journal.json),
[copy histogram](results/copy_ram_journal.json).

## Nx 1.0 buffer donation

Nx 1.0 adds `Nx.donatable/1`, which supplies the ownership contract that was
missing from the 0.13 implementation. The compiled frame runner marks RAM and
WRAM as donatable and returns them as the first explicit outputs so EXLA pairs
each input with the intended same-shape output. ROM and CHR are never donated.
The returned state owns the buffers; callers must replace the old state and must
not read it after calling the runner.

On EXLA's host client, RAM and WRAM retain their exact pointer addresses across
three consecutive native-exact frames. This establishes zero-copy state transfer
at the compiled frame-call boundary using only Elixir/Nx APIs. A compatibility
normalizer adds the new tensor metadata field when loading checkpoints serialized
by Nx 0.13.

Donation does not alter XLA's copies inside nested compiled loops. The final
five-frame probe reports **1.0494 GB/frame**, effectively unchanged from the
RAM-journal result, at **451.1 ms/frame (2.217 FPS)**. The distinction is now
measured: cross-frame RAM/WRAM ownership is solved, while the remaining copy
volume is generated within the frame computation.

Results: [timing](results/copy_bench_donatable.json),
[copy histogram](results/copy_donatable.json).

## Batched PPU row commit

`PPU.commit_lines/2` now applies its eight-slot scanline queue with one
`Nx.indexed_put/3` instead of a compiled loop containing one `Nx.put_slice/4`
per rendered row. Rendered rows are consecutive and a CPU step produces at most
six, so unused slots target eight distinct rows outside that span and write back
their existing pixels. This avoids the repeated-index behavior documented for
`indexed_put` and preserves the public 240 by 256 framebuffer.

The framebuffer joins RAM and WRAM as an explicitly donated input/output. RAM
and WRAM retain their pointer addresses across exact frames. EXLA may allocate a
different framebuffer result, so framebuffer pointer identity is not assumed.
The per-frame 60 KiB framebuffer CopyThunk is gone. Total measured traffic is
**1.04934 GB/frame**, versus **1.04940 GB/frame** before this change; the remaining
volume is still dominated by nested 2/4/8 KiB state copies.

The more meaningful gain is fewer runtime thunks. Five exact checkpoint frames
with the existing sequential-scheduler diagnostic average **408.45 ms/frame
(2.448 FPS)**, versus **451.07 ms/frame (2.217 FPS)** before the batched commit.
Plain EXLA averages **665.87 ms/frame (1.502 FPS)** over three exact frames,
versus **686.91 ms/frame (1.456 FPS)** for a matched pre-change run. The native
interposer remains diagnostic-only and is not part of the emulator.

Results: [sequential timing](results/copy_bench_ppu_scatter.json),
[plain EXLA timing](results/copy_bench_ppu_scatter_plain.json),
[copy histogram](results/copy_ppu_scatter.json).

Two larger alternatives were rejected. A scanline-per-EXLA-call runner remained
exact but fell to 1.46 FPS and raised traffic to 1.153 GB/frame because PRG and
CHR became loop inputs on every call. A vectorized closed-form APU filter was
also byte-exact over the 15-second capture, but prefix-sum and matrix forms were
slower than the existing 128-sample recurrent loop. These experiments confirm
that `Nx.donatable/1` controls executable-call ownership; it does not add mutable
semantics to nested `while` state. Nx containers describe traversal and tensor
structure, and `Nx.Pointer` is an interop handle rather than a compiled load/store
API. There is no additional documented Nx function that makes an inner XLA loop
mutate a tensor in place.

## Reproduce

Run from `experiments/nx_nes` using Elixir 1.20.2 / OTP 29.0.3 and `MIX_ENV=prod`.
Create a live checkpoint with `machine_bench.exs`, then preserve it before any
new full benchmark overwrites `tmp/machine/checkpoint.etf`.

```sh
python3 build_copy_probe.py
python3 build_scheduler_probe.py
```

For the uninstrumented checkpoint benchmark:

```sh
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so \
NX_APU_FORCE_SEQUENTIAL=1 \
mix run copy_bench.exs --checkpoint tmp/saved_checkpoint.etf --frames 10 \
  --output results/copy_bench_optimized.json
```

For the counter, append `$PWD/tmp/copy_probe.so` to `LD_PRELOAD` and set
`NX_COPY_REPORT=/tmp/copies.csv`. Its destructor writes the histogram after
the process exits. That histogram includes warmup. Counts over 1 MiB use an
overflow bucket; no such copies occur in this workload. The probe is compiled
against the exact bundled XLA C++ ABI with `NDEBUG`, and never loads by default.

For static compiler diagnostics, add:

```sh
XLA_FLAGS='--xla_dump_to=/tmp/nx-copies --xla_dump_hlo_as_text'
```

The before measurement uses the frame runner from `65fd218`. The paired local
harness loads that source under a separate module name, using the unchanged
non-queued memory and standalone PPU paths, then runs the optimized runner
from the same checkpoint. For an independent historical reproduction, use a
checkout of `65fd218` with this checkpoint benchmark script.
