# Ten-opcode branchless CPU prototype

This prototype tests table-driven, branchless CPU execution independently of
the complete emulator. It implements ADC, AND, BNE, CLC, DEX, INC, JMP, LDA,
LDX, and STA. Opcode metadata comes from constant 256-entry tensors. The step
computes supported address and ALU candidates, selects the active results, and
performs one masked `Nx.indexed_put/3` against 2 KiB mirrored RAM. A second
runner accumulates up to eight writes in small key/value tensors, forwards
reads from the newest matching entry, and flushes those writes to RAM in order.

The synthetic NROM program executes all ten operation classes. After 100,000
instructions, the prototype's registers, flags, PC, cycle count, and complete
RAM are exact against `NxNes.Core.CPU`. Inputs are copied to the EXLA host client
before timing, and each measured run is one compiled call.

| Runner | Median runtime | Compile time |
| --- | ---: | ---: |
| Eight-write journal | **2.429 ms** | 74.160 ms |
| Direct 2 KiB RAM update | 28.032 ms | 83.404 ms |
| Complete conditional CPU | 4,385.688 ms | 1,126.952 ms |

The journal is **11.5x faster** than the otherwise equivalent direct runner and
roughly **1,806x faster** than the complete conditional CPU in this favorable
test. The prototype does much less work than the complete CPU, so the second
ratio is not a projected full-core speedup. At Castlevania III's observed
average of roughly 9,200 instructions per frame, the subset journal rate
corresponds to about 0.22 ms of CPU time. Full opcode, addressing, mapper,
interrupt, DMA, and MMIO handling will add cost.

The donated RAM input and output had the same `Nx.Pointer.address` in the
recorded benchmark, showing call-boundary buffer reuse in that run. The XLA
CopyThunk probe nevertheless reports, per 100,000-instruction run:

- 200,000 copies of 2,048 bytes
- 100,001 copies of 64 bytes
- 416,000,068 copied bytes in total

Donation therefore does not make the direct runner's inner `while` update
physically in-place. Its two full RAM copies per instruction come from
loop-carried functional state and the masked indexed update.

The journaled runner instead reports only 20,076 copied bytes and 5,004
CopyThunks per 100,000-instruction call. It has no 2 KiB CopyThunks. That is
about **20,721x less copied data** than direct updates. The hot instruction loop
carries an eight-entry journal; the outer loop carries RAM and flushes after
eight actual writes, in program order. The 2 KiB RAM input/output pointer is
also reused across each compiled call.

The result supports expanding branchless opcode coverage with the journal as
the state-write mechanism. Each stage must retain an exact differential test
and track compile time, runtime, and CopyThunk traffic. Mapper and PPU register
writes will need ordered journals of their own because reads can observe their
side effects before the end of a frame.

Result: [journal benchmark](results/branchless_cpu_journal.json),
[journal copy histogram](results/branchless_cpu_journal_copies.json). The
[direct benchmark](results/branchless_cpu_10ops.json) and
[direct copy histogram](results/branchless_cpu_10ops_copies.json) remain as the
pre-journal baseline.

Run from this directory with Elixir 1.20.2 / OTP 29.0.3 and `MIX_ENV=prod`:

```sh
mix run branchless_cpu_bench.exs --instructions 100000 \
  results/branchless_cpu_journal.json
```
