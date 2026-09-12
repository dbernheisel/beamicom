# Ten-opcode branchless CPU prototype

This prototype tests table-driven, branchless CPU execution independently of
the complete emulator. It implements ADC, AND, BNE, CLC, DEX, INC, JMP, LDA,
LDX, and STA. Opcode metadata comes from constant 256-entry tensors. The step
computes supported address and ALU candidates, selects the active results, and
performs one masked `Nx.indexed_put/3` against 2 KiB mirrored RAM.

The synthetic NROM program executes all ten operation classes. After 100,000
instructions, the prototype's registers, flags, PC, cycle count, and complete
RAM are exact against `NxNes.Core.CPU`. Inputs are copied to the EXLA host client
before timing, and each measured run is one compiled call.

| Runner | Median runtime | Compile time |
| --- | ---: | ---: |
| Ten-opcode branchless | **32.223 ms** | 88.122 ms |
| Complete conditional CPU | 4,398.565 ms | 1,118.777 ms |

The restricted branchless body is **136.5x faster** in this favorable test. It
does much less work than the complete CPU, so this ratio is not a projected
full-core speedup. At Castlevania III's observed average of roughly 9,200
instructions per frame, the subset rate corresponds to about 3 ms of CPU time.
Full opcode, addressing, mapper, interrupt, DMA, and MMIO handling will add cost.

The donated RAM input and output have the same `Nx.Pointer.address`, proving
call-boundary buffer reuse. The XLA CopyThunk probe nevertheless reports, per
100,000-instruction run:

- 200,000 copies of 2,048 bytes
- 100,001 copies of 64 bytes
- 416,000,068 copied bytes in total

Donation therefore does not make the inner `while` update physically in-place.
The two full RAM copies per instruction come from loop-carried functional state
and the masked indexed update. Despite 416 MB of internal traffic, the simple
branchless program sustains the copies and arithmetic efficiently. The current
complete core's large conditional graph and runtime thunk scheduling are the
larger performance problem.

The result supports expanding branchless opcode coverage in stages. Each stage
must retain an exact differential test and track compile time, runtime, and
CopyThunk traffic. Memory journaling or page decomposition can be evaluated
after the complete branchless body establishes its actual write/copy cost.

Result: [benchmark](results/branchless_cpu_10ops.json),
[copy histogram](results/branchless_cpu_10ops_copies.json).

Run from this directory with Elixir 1.20.2 / OTP 29.0.3 and `MIX_ENV=prod`:

```sh
mix run branchless_cpu_bench.exs --instructions 100000 \
  results/branchless_cpu_10ops.json
```
