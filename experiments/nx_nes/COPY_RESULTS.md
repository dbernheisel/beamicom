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
The pass is local to this experiment and depends on Nx 0.13.1 expression
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
