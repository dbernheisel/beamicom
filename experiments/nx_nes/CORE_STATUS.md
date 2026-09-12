# Resident Nx CPU/bus milestone

For the newer live MMC5 integration, see [the resident frame runner](MACHINE_RESULTS.md).
This document describes the earlier isolated CPU/bus milestone and its benchmark.

The optional Nx CPU/bus prototype is implemented separately from the native
Elixir emulator. It passes the complete 8,991-row nestest trace and differential
instruction tests, but the general tensor interpreter is substantially slower
than native Elixir. It is a correctness/scheduling foundation, not yet a playable
Nx NES implementation or a demonstrated full-core speedup.

## Native Elixir remains independent

`beamicom/lib/nes` remains the production implementation. Its Mix project still
depends only on the sibling `beamicom_host`; it has no Nx, EXLA, native-C APU, GPU,
or ROCm dependency. Applications using `Beamicom.NES.System` keep that path.

The new implementation lives under `experiments/nx_nes/lib/nx_nes/core*`, within
the existing separate experiment project. No production backend selection or
replacement was installed. Systems without XLA can continue using native Elixir.

## Implemented

- Resident NROM PRG-ROM, CHR storage, 2 KiB mirrored CPU RAM and 8 KiB WRAM.
  NROM-128/256 PRG mapping and ROM write protection are covered.
- CPU registers, flags, addressing modes, page-cross/branch cycle penalties,
  stack, subroutines, BRK/RTI, and explicit NMI/IRQ entry at instruction boundaries.
- The 239 opcode entries implemented by the native core, covering 71 operations.
  Unimplemented bytes stop explicitly instead of inheriting the native decoder's
  default NOP behavior.
- Runtime instruction/operand fetch from tensors, including executable RAM.
  The interpreter is ROM-driven rather than specialized to the old hot loop.
- Controller strobes and serial reads for both ports; input masks remain resident.
- Instruction-count and absolute-cycle bounds, plus explicit device read/write
  barriers. An instruction that cannot complete within a deadline commits no
  CPU, RAM, or controller changes.
- Device response/retry protocol, including a read-modify-write instruction that
  requires both a read response and a write acknowledgment before it commits.
- Resident batched trace output for differential validation.

The opcode dispatcher uses a balanced tree. A first long linear conditional
chain crashed the bundled native StableHLO-to-HLO conversion; balancing the
branches avoids that failure and compiles in about 1.1 seconds.

## API

```elixir
{:ok, state} = NxNes.Core.load(rom_binary)
run = EXLA.jit(&NxNes.Core.CPU.run/3, client: :host)

{state, instructions} =
  run.(state, Nx.tensor(deadline, type: :s64), Nx.tensor(limit, type: :s32))

NxNes.Core.stop(state)
# :deadline | :instruction_limit | :device_read | :device_write |
# :unsupported_opcode | :instruction_fetch
```

Device barriers report `event_addr`, `event_value`, `event_cycle`, and `opcode`.
CPU state is still at the instruction's entry. After a device handler supplies
its read value or actually handles its write, use `Core.respond(state, value)`
(for reads) or `Core.respond(state)` (write acknowledgment), then retry execution.
The response is consumed only when the instruction successfully commits.

This protocol is a prototype integration boundary. A caller must not perform a
device write speculatively and then roll peripheral time backward. The current
scheduler bounds whole instructions conservatively; it does not provide a
cycle-by-cycle suspended CPU microstate. Full PPU/NMI/DMA integration requires
that timing work rather than treating these synthetic deadlines as a complete
hardware scheduler.

## Validation

`cpu_nestest.exs` compares PC/A/X/Y/P/SP/CYC against all **8,991 published rows**.
Five device writes in the test epilogue are handled explicitly by the native APU
and acknowledged; they are not silently ignored. The full trace is also in the
ExUnit regression suite.

Instruction differential tests cover every supported opcode under three register/
flag/stack configurations, comparing CPU registers/cycles and full RAM/WRAM with
native Elixir. Cases that address unimplemented devices must stop transactionally.
Other tests cover deadlines, exact boundaries, repeated resident calls, device
read/write/RMW response handling, mirroring, immutable ROM, controllers, NMI/IRQ
stack/vector entry, and unsupported inputs. The native project's own nestest test
also passes independently.

## Performance gate

`cpu_bench.exs` executes the complete 8,991-instruction nestest workload with
conservative synthetic horizons corresponding approximately to a scanline,
APU sequencer interval, and frame. It handles the same five APU writes explicitly.
No PPU, live APU timeline, DMA, or mapper interrupts run during timing. Initial
uploads and compilation are excluded; output synchronization, host boundary
handling, and five-write acknowledgments are included.

Five repeated runs rotate implementation order after warmup. Final registers,
cycles, and RAM match native Elixir. The sequential diagnostic uses the existing
process-local thunk override and is not enabled in normal configuration.

| CPU implementation / horizon | Default median | Sequential diagnostic median |
| --- | ---: | ---: |
| Native Elixir | 2.126 ms | 2.130 ms |
| Nx, 114 cycles (238 calls) | 460.876 ms | 228.690 ms |
| Nx, 7,457 cycles (9 calls) | 389.064 ms | 202.725 ms |
| Nx, 29,830 cycles (6 calls) | 366.265 ms | 202.443 ms |

The large-horizon general Nx interpreter remains about **172x slower** than native
under default settings, and about **95x slower** with the diagnostic override.
These numbers are for this instruction-test workload, not game FPS. They do not
contradict the older specialized six-instruction hot-loop result: that kernel
eliminated general decoding/dispatch, whereas this one handles arbitrary code.
Reducing host crossings alone barely changes the result. A general CPU port must
address compiled instruction execution before replacing the native CPU.

Artifacts: `results/cpu_nestest.json`, `results/cpu_bench.json`, and
`results/cpu_bench_sequential.json`.

## Remaining core work

The first [ROM-specialized block compiler](BLOCK_CPU_RESULTS.md) now fuses
straight-line instructions and retains the general CPU fallback. It makes the
captured hot loop faster than native in a single resident call, but frequent
host returns and partial-block fallback still lose to native. This is a favorable
CPU-only loop, not full-game performance. Next investigate compiled block
prefixes/suffixes and an internal device scheduler before broadening the rewrite.
An integrated CPU can then drive live device control state and feed the existing
batched PPU/APU output kernels.

The isolated `NxNes.Core` API remains CPU-only. The separate `NxNes.Machine`
now integrates MMC5, live PPU/APU control, NMI/IRQ handling, OAM DMA and frame
publication. DMC DMA, other mapper integration and a portable save-state format
remain outstanding. See its dedicated results and API before using a frame runner.

The separate [ROCm investigation](ROCM_INVESTIGATION.md) successfully runs PPU and
block APU correctness smoke tests on Radeon 8060S through an isolated patched
EXLA/PJRT adapter. That proves backend execution, not a GPU speedup.

## Reproduce

From `experiments/nx_nes` with the project's Elixir/OTP versions:

```sh
MIX_ENV=prod mix run cpu_nestest.exs
MIX_ENV=prod mix run cpu_bench.exs
MIX_ENV=prod mix run build_native.exs # earlier optional native-audio control used by its tests
MIX_ENV=test mix test
```

For the optional diagnostic comparison, first build the scheduler probe as
explained in `NX_APU_PROFILE.md`, then:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run cpu_bench.exs results/cpu_bench_sequential.json
```

Native fallback validation, from `beamicom`, requires no Nx experiment setup:

```sh
MIX_ENV=test mix test test/nes/cpu_nestest_test.exs
```
