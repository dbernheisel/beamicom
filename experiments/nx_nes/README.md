# Resident Nx NES experiment

For the subsequent copy-removal optimization, see [buffer-copy results](COPY_RESULTS.md).

Restore point: `9755cc8` (`main`). The production CPU, PPU, APU and mapper code
has not been changed. Nx/EXLA are dependencies of this separate project only.

The experiment now implements and measures MMC5 graphics and audio kernels,
including a native C audio loop that substantially outperforms the Nx audio loop
on the isolated continuous workload.
See [MMC5 device results](DEVICE_RESULTS.md) for that work, its validation,
measured gains/slowdowns, and integration limits. The CPU-only results below
describe the initial checkpoint.

For the measured cause of the Nx APU slowdown, see [Nx APU runtime profile](NX_APU_PROFILE.md): a scheduling-only intervention removes about 62% of elapsed time.

[Timestamped audio-block results](APU_BLOCK_RESULTS.md): the new Nx block renderer
matches the full Castlevania capture and runs 15.66x faster than the matched scalar
Nx loop, or 2.84x faster than Elixir, under default XLA scheduling.

[Resident MMC5 frame runner](MACHINE_RESULTS.md): Castlevania III now executes
from reset with CPU, banking, PPU, DMA, interrupts and audio inside Nx. Native
Elixir remains independent. See the full-workload validation and timing there.
Branchless CPU/address/device dispatch, branchless scheduler gating and targeted
state donation complete the 902-frame cold-boot workload exactly in 298.434
seconds (3.022 FPS), a 28.7% time reduction from the previous optimized resident
core. The generic graph now outperforms the guarded hot-block variant.

[Resident CPU/bus milestone](CORE_STATUS.md): full nestest parity and transactional
device/deadline boundaries are implemented, while native Elixir remains independent.
The general Nx interpreter is currently much slower; see the measured performance
gate before interpreting earlier specialized CPU gains.

[ROM-specialized CPU blocks](BLOCK_CPU_RESULTS.md): automatic straight-line
fusion now has a guarded interpreter fallback. The captured loop beats native
in a single call; frequent deadlines still expose substantial overhead.

[ROCm investigation](ROCM_INVESTIGATION.md): GPU arithmetic, PPU, and block APU
correctness probes now run through an isolated EXLA/PJRT adapter.

## Objective and current status

The proposed machine keeps the complete ROM, writable memories, CPU registers,
mapper state, PPU and APU state in EXLA CPU buffers. Host calls supply controller
input and receive completed framebuffer/audio output. Internal state stays on
the backend between calls. Loading, debugging and saving are explicit exceptions.

**This is an experimental Nx NES core, currently much slower than real time.** The baseline
and function profile cover the complete existing emulator. The Nx measurement
initially covered one real, validated CPU loop, with devices and interrupts excluded.
The subsequent general CPU/bus prototype and audio/graphics experiments are linked above.
The live MMC5 runner now provides full-ROM correctness and performance measurement.
Its API is separate from the production application UI.

## Measurements

Machine: AMD Ryzen AI Max+ 395, 32 logical CPUs; Elixir 1.20.2, OTP 29.0.3;
Nx and EXLA 1.0.0; EXLA `:host` client. No GPU. Performance runs use `MIX_ENV=prod`.

`results/baseline.json` records 902 frames (approximately 15 seconds of emulated
NTSC time) from cold boot, no buttons pressed, full audio and video enabled.
There is an untimed warmup of the same workload followed by three fresh runs.
The core runs uncapped; rendering/encoding/playback in an external client is not
included. Frame timers exclude output hashing; wall timers include it.
Frame, PCM and final-state hashes must match across repetitions.
This is a boot/title/attract workload, not a claim about all gameplay scenes.
The final three-run baseline has median core time 10.77 seconds, 83.7 FPS
(1.39x real time), mean frame time 11.94 ms and p95 frame time 12.60 ms.
All runs have zero frames over budget. Earlier trials were approximately 86 FPS;
a separate fresh-VM verification reached 89.9 FPS and matched every output hash,
sample count and CPU cycle count (`results/baseline_fresh_vm.json`). These are
uncontrolled desktop measurements, not frequency-pinned laboratory results.

`results/profile.txt` is a separate full-workload OTP `tprof` call-time profile.
Its instrumentation overhead makes its elapsed times unsuitable as FPS results.
Aggregated self-time by module: CPU ~33.1%, bus ~14.1%, PPU ~24.5%, APU ~11.5%.
`binary:at/2` contributes another ~8.9% across callers. CPU decode is only ~1.2%.
Inlining and tracing overhead affect attribution; these are hotspot indicators.

`results/hot_pcs.txt` records instruction counts for the hottest bank/address
pairs. Six addresses in a loop account for about 59% of the 8.30 million
instructions in this workload. This ROM uses MMC5 (mapper 5).

`results/resident_probe.json` compares 65,536 iterations / 393,216 instructions
of that loop, with the captured CPU/RAM entry state. The complete 393,232-byte
ROM file, 2 KiB CPU RAM and a 64 KiB cartridge-RAM address image are resident
tensors. The kernel reads operand addresses from resident ROM; it specializes
the validated instruction sequence. Cartridge RAM and ROM stay unchanged.
The 64 KiB image represents the current CPU-address-keyed snapshot, not a
general implementation of every bank of MMC5 cartridge RAM.

Representative median results:

| Execution | Time | Versus headless interpreter |
| --- | ---: | ---: |
| Existing CPU interpreter, devices disabled | 99.0 ms | 1.0x |
| Specialized Elixir block, devices disabled | 9.3 ms | 10.6x |
| Nx, 256 loop iterations per call | 29.4 ms | 3.4x |
| Nx, 4,096 loop iterations per call | 16.2 ms | 6.1x |
| Nx, all iterations in one call | 15.7 ms | 6.3x |
| Nx, one loop iteration per call | 3,825.0 ms | 0.026x |

Compilation took about 63 ms and is excluded from warm execution timings.
The timer includes dispatch and synchronization of final RAM/cycles. Register
and memory comparisons happen outside it. Output state is fed directly into the
next compiled call; ROM/RAM are not converted back to binaries between calls.

**Specialization helps, but Nx did not beat equivalent specialized Elixir in
this probe.** Do not extrapolate the 6.3x CPU-loop result to full-game FPS.
Long batches here cross hardware deadlines because this is a headless probe;
they are not safe scheduling choices for the complete machine.

## Plan and decision checkpoints

1. **Baseline and feasibility (implemented).** Keep the existing emulator as the
   reference, collect full-game timings/hashes, identify actual hot blocks, and
   compare resident Nx against both the interpreter and specialized Elixir.
   Differential tests exercise wraparound, overflow, source/destination aliasing,
   repeated resident calls, unchanged ROM, and unsupported-code rejection.
2. **Broaden the CPU comparison before a full port.** Add a ROM-driven tensor
   interpreter and additional analyzed blocks with indirect addressing, stack
   access, branches, and RAM writes. Inspect optimized XLA IR/buffer assignments
   for copies and scalar-operation costs. Measure compile time, memory use, and
   realistic batch sizes. Keep an equally specialized Elixir control. Resident
   storage alone does not compile instructions: graph generation is separate.
3. **Implement resident scheduling and the MMC5 bus.** Represent distinct RAM,
   PRG/CHR bank maps, cartridge RAM, registers and interrupt latches explicitly.
   Preserve bank changes and memory-mapped side effects. Execute to the next
   observable event with the existing CPU's access/interrupt ordering; do not
   bulk-add cycles after operations that could observe devices. Guard compiled
   ROM blocks by mapping/mode and invalidate RAM code when written.
4. **Port PPU and APU state transitions into compiled execution.** Include MMC5
   graphics, scanline interrupts, expansion audio, controllers, DMA and DMC.
   Use fixed-shape video/audio buffers plus valid counts. All internal device
   interactions stay in the compiled computation. Host callbacks per instruction
   are not the desired final architecture. Match the reference's current timing
   semantics first; separate accuracy changes from performance changes.
5. **Expose the requested boundary.** `load(media)` creates resident state;
   `run_frame(state, input)` returns resident state, framebuffer and PCM. Transfer
   only completed outputs during normal playback. Precompile required shapes
   before measurement and report cold compile time separately.
6. **Repeat the exact 902-frame comparison.** Require matching frame/PCM hashes,
   sample counts, and canonical hardware state. Run alternating baseline/Nx
   trials without profiling or competing builds, compare median and tail frame
   times, and include output transfers. Add a deterministic gameplay input script
   after the original no-input case. Retain the reference backend.

The current result argues for checkpoint 2, not assuming a complete tensor port
will be faster. A full resident core may gain from compiled device work and fewer
state updates, but that remains unmeasured. NES first; GBC and SNES would share
the residency/benchmark design, not the hardware implementations.

## Reproduction

Use the repository's toolchain (`mise exec elixir@1.20.2-otp-29 erlang@29.0.3 --`
before each command if the shell selects a different installation).

From `beamicom/`:

```sh
MIX_ENV=prod mix nes.bench roms/castlevania3.nes --seconds 15 --repeats 3 --output ../experiments/nx_nes/results/baseline.json
MIX_ENV=prod mix nes.bench roms/castlevania3.nes --seconds 15 --profile-only > ../experiments/nx_nes/results/profile.txt
```

From `experiments/nx_nes/`:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix run trace.exs ../../beamicom/roms/castlevania3.nes > results/hot_pcs.txt
MIX_ENV=prod mix run probe.exs ../../beamicom/roms/castlevania3.nes
mix test
```

Run timings sequentially. The instruction collector is instrumented and is not
a timing benchmark. `tmp/hot_snapshots.etf` contains local ROM-derived state and
is intentionally ignored by Git; no ROM or snapshot is included in the source.
