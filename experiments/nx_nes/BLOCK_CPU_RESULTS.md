# ROM-specialized Nx CPU blocks

`NxNes.Core.Blocks` analyzes a bounded straight-line region of NROM and builds
an Nx graph from its known instruction bytes. Register values and RAM stay
runtime tensors. Direct RAM reads forward earlier stores in the same block;
only the final value for each modified address is written back. This lets XLA
remove intermediate flags and redundant loads/stores without a hand-written
six-instruction kernel.

The existing general Nx interpreter remains the fallback. The production native
Elixir core and its dependencies are unchanged.

## Boundaries and scope

- Immediate and direct internal-RAM loads, stores, arithmetic, comparisons,
  BIT, INC/DEC; implied register/flag operations; and absolute JMP are supported.
- Analysis stops at other instructions, device accesses, indexed/indirect
  addressing, or the instruction cap (default 16, maximum 64).
- One block is specialized per compiled runner. Other PCs use `CPU.step`.
- Each call checks the compiled bytes against resident PRG and checks the NROM
  mapping mask. Changed code falls back. ROM and RAM remain resident.
- A whole block runs only when its cycle cost and instruction count fit the
  caller's remaining bounds. Partial blocks and pending device responses use
  the generic interpreter. Whole instructions never commit past a deadline.
- No live mapper, PPU/APU scheduler, DMA, or interrupt-edge integration is added.
  This inherits the CPU milestone's conservative instruction-boundary contract.

## API

```elixir
{:ok, state} = NxNes.Core.load(media, pc: entry)
{:ok, block} = NxNes.Core.Blocks.analyze(media, entry)
run = EXLA.jit(fn state, deadline, limit ->
  NxNes.Core.Blocks.run(state, deadline, limit, block: block)
end, client: :host)
{state, instructions, compiled_blocks} =
  run.(state, Nx.tensor(deadline, type: :s64), Nx.tensor(limit, type: :s32))
```

Callers should cache the compiled runner. Analysis returns
`{:error, :no_compilable_instructions}` for an unsupported entry; use `CPU.run`
there. Analysis is explicit code discovery, not speculative linear disassembly
of an entire ROM that mixes executable code and data.

## Benchmark method

`blocks_bench.exs` takes the recorded Castlevania III snapshot at `$E047`, freezes
its mapped 32 KiB PRG view into an NROM image, and retains its registers and RAM.
The unchanged instruction bytes compile automatically to a six-instruction,
19-cycle block. All implementations execute 8,192 iterations / 49,152 instructions.
The native reference uses the same frozen mapping and state.

This isolates CPU work. It does **not** run Castlevania III with live MMC5 or
provide an emulator FPS number. The hot loop is favorable code; its result
cannot establish performance for other code or a general game workload.

Timing excludes initial state upload and compilation, includes output
synchronization and host calls, and rotates variant order across five runs after
validation/warmup. Every variant matches final native registers, cycles, and full
RAM. Horizons 113 and 114 approximate scanline-sized intervals; neither is a
complete PPU timing model. The 114-cycle horizon fits exactly six loop iterations,
while 113 exercises partial-block fallback. The long horizon permits one call.

| Implementation / horizon | Default median | Sequential diagnostic median |
| --- | ---: | ---: |
| Native Elixir | 12.485 ms | 11.884 ms |
| Generic Nx, one call | 2392.004 ms | 1256.122 ms |
| Fused Nx, one call | 8.369 ms | 1.506 ms |
| Fused Nx, 7,457 cycles / 21 calls | 16.099 ms | 6.328 ms |
| Fused Nx, 114 cycles / 1,366 calls | 131.427 ms | 100.916 ms |
| Fused Nx, 113 cycles / 1,378 calls | 513.622 ms | 319.950 ms |

The default single-call fused runner is **286x faster** than the generic Nx
interpreter and **1.49x faster** than native on this loop. With the
process-local sequential diagnostic, it is **7.89x faster** than native.
Compilation took 1168 ms default / 1143 ms sequential and is excluded.

At 113-cycle deadlines, only 43,050 of 49,152 instructions fuse (87.6%). The
remaining 6,102 instructions take the generic path. At 114 cycles all instructions
fuse, yet frequent host returns still cost substantially more than native.
At 7,457 cycles, 49,062 instructions fuse and 90 use the fallback.
These comparisons expose both a partial-block penalty and a host-return penalty;
they do not measure an exact profiler attribution between runtime mechanisms.

The next work should compile block prefixes/suffixes for interrupted runs and
keep device scheduling inside Nx, before expanding opcode coverage or claiming a
full-core win. A single cached block is not a complete ROM compiler. Broad workload
coverage, code-cache design and compilation cost remain unmeasured.

Raw samples and coverage counts are in `results/blocks_bench.json` and
`results/blocks_bench_sequential.json`. These are unpinned shared-desktop runs;
there are visible timing outliers, so the table reports medians of five runs.


## Correctness

The complete experiment suite passes: **26 tests**, including the existing
CPU nestest, PPU, and APU regressions. Formatting and whitespace checks pass.

`test/blocks_test.exs` compares every state field with the generic CPU across
all deadlines from 7 through 65 and instruction limits that cut through blocks.
It checks changed-ROM fallback, device write/acknowledgment, pending read
responses, mirrored RAM aliases, overflow, and store forwarding. Every opcode
accepted by the compiler is compared against native Elixir under three register/
flag/stack configurations. The per-opcode test allows 180 seconds because it
compiles a separate EXLA runner for each accepted opcode.

## Reproduce

From `experiments/nx_nes`, with the project's Elixir/OTP versions:

```sh
# Only if the ignored capture is absent; uses the user's local ROM.
MIX_ENV=prod mix run trace.exs ../../beamicom/roms/castlevania3.nes
MIX_ENV=prod mix run blocks_bench.exs
MIX_ENV=test mix test test/blocks_test.exs
```

The optional sequential diagnostic uses the probe described in
[Nx APU profiling](NX_APU_PROFILE.md), without changing default EXLA configuration:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run blocks_bench.exs results/blocks_bench_sequential.json
```
