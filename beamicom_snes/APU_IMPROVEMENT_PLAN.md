# SNES APU improvement plan

This plan takes the SNES audio core from its current useful-but-approximate
state to a conformance-oriented S-SMP/S-DSP implementation, then adds an
optional Nx-powered enhancement path. The enhancement is deliberately a core
feature rather than an `AudioSink` mastering filter: it may operate on voices
and DSP buses, but only after the authentic renderer is a trustworthy baseline.

The work packages below are intended to be handed to separate agents. Each
package has an explicit dependency and ownership boundary so agents can work in
parallel without repeatedly merging competing rewrites of `apu.ex` or `dsp.ex`.

## Outcome and non-goals

The completed work should provide:

- an authentic renderer with tested SPC700, S-SMP, and S-DSP timing;
- deterministic, versioned APU save state;
- native and Nx renderers that produce identical authentic PCM;
- an opt-in enhanced renderer that can add dynamics, bass weight, harmonic
  character, and improved spatial/echo treatment from internal DSP signals;
- automatic native fallback when Nx or a supported backend is unavailable.

This plan does **not** replace game samples, reinterpret music driver data,
change the authentic mode by default, or commit third-party conformance ROMs.
The enhancement path is experimental until the accuracy gate near the end of
this document is met.

## Current baseline

Treat the source and tests as authoritative; the APU section of
`IMPLEMENTATION_STATUS.md` currently understates what is implemented.

- SPC700 dispatch covers all 256 opcode bytes, with limited instruction- and
  bus-sequence validation.
- SPC work runs at 1.024 MHz and PCM is emitted at 32 kHz stereo.
- DSP and RAM writes carry SPC memory-access timestamps and are applied at
  their exact phase barriers.
- One authoritative 32-phase DSP pipeline implements eight voices, BRR
  filters/looping, Gaussian interpolation, ADSR/GAIN, KON/KOFF, PMON/NON,
  echo/FIR, live registers, and hardware-ordered bus clipping.
- Focused APU and DSP tests currently pass.
- The historical Nx block synthesizer remains available as an experimental
  module, but the authentic runtime does not route through it until its complete
  phase state and shared-RAM transition can match the scalar oracle.
- Blargg SPC fixture support exists, but the ROM files are local-only and may
  be absent. Missing fixtures cause the corresponding tests to skip.

Remaining accuracy gaps include:

- broader external validation of rare per-phase register and RAM collisions;
- S-SMP TEST behavior, timer edge cases, I/O collisions, and exact MMIO access;
- opcode fetch and remaining SPC700 instruction bus sequences;
- distinct SLEEP/STOP behavior and realistic power-on state.

## Ground rules for every agent

1. Preserve authentic mode as the default and keep it deterministic.
2. Add a failing focused test or reference vector before changing behavior.
3. Use integer/fixed-point hardware arithmetic in authentic mode. Do not use
   host floating point to approximate observable DSP behavior.
4. Keep clocking, latches, register semantics, and RAM mutation in native
   control code unless a proven Nx kernel can preserve the same order exactly.
5. Nx code must be a replaceable execution backend, not the definition of
   correctness. The scalar implementation is the oracle.
6. Version any save-state shape change and test loading the previous version.
7. Do not commit proprietary or ambiguously licensed ROM binaries. Preserve
   fixture provenance and hashes for locally installed test material.
8. Keep unrelated working-tree changes intact. An agent should edit only the
   files assigned to its package unless its prompt explicitly expands scope.
9. Finish each package with:

   ```console
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test test/beamicom/snes/apu_test.exs test/beamicom/snes/dsp_test.exs
   ```

   Add the package's focused tests to that command. Run the full `mix test`
   before merging a wave.

## Dependency map

```text
A00 reference harness ─┬─> A20 clocked DSP skeleton ─> A30 shared timeline
                       │                              ├─> A40 voice pipeline
                       │                              ├─> A50 noise + PMON
                       │                              └─> A60 echo + FIR
                       └─> A10 S-SMP/SPC700 accuracy ───────┘

A30 + A40 + A50 + A60 + A10 ─> A70 conformance gate
A70 ─> A80 authentic Nx parity ─> E10 enhanced Nx synthesis ─> E20 product gate
```

`A10` may run alongside `A20` through `A60` because it owns `spc700.ex`, while
the DSP stream owns separate files. `A40`, `A50`, and `A60` may run in parallel
only after `A20` freezes their module interfaces. One integration agent should
remain the sole writer to `apu.ex` and the top-level `dsp.ex` during that wave.

## Accuracy work packages

### A00 — Reference vectors and regression harness

**Depends on:** nothing  
**Owns:** new test-support modules and fixtures, focused test files, fixture
documentation; no production behavior

Build the measurement foundation before changing synthesis.

Deliverables:

- A table-driven DSP trace harness that can set RAM/registers, advance an exact
  number of DSP clocks, and inspect PCM, registers, voice state, and RAM.
- Small, original vectors for signed arithmetic, clamp points, interpolation,
  envelopes, KON/KOFF, ENDX, BRR transitions, echo, noise, and PMON.
- A way to compare scalar output and state against a trusted reference without
  incorporating reference emulator source into Beamicom.
- Clear local installation instructions for the existing Blargg SPC suite and
  an explicit test result of `pass`, `fail`, or `skipped: fixture missing`.
- Golden PCM/state hashes that encode the vector version and renderer identity.

Acceptance criteria:

- A deliberately corrupted sample, register, or RAM byte produces a readable
  first-divergence report with clock/sample index and expected/actual values.
- The harness can run both a single clock and a multi-sample block.
- Existing scalar/Nx equality tests still pass.
- No third-party ROM binary is added to Git.

Suggested agent prompt:

> Implement work package A00 from `APU_IMPROVEMENT_PLAN.md`. Restrict changes to
> APU/DSP test support, focused tests, and fixture documentation. Do not change
> emulator behavior. Report the baseline conformance results, including skips.

### A10 — SPC700 and S-SMP correctness

**Depends on:** A00 harness conventions  
**Owns:** `spc700.ex` and new SPC700/S-SMP-focused tests

Deliverables:

- Route opcode fetches through the correct memory/MMIO access path so reads in
  `$F0-$FF` have the documented side effects.
- Implement TEST (`$F0`) semantics: clock controls, RAM-write disable, and
  timer/test behavior relevant to software.
- Correct timer target write-only reads, divider/output phase, enable edges,
  target writes, four-bit wrap, and read-clear behavior.
- Validate CONTROL, DSPADDR/DSPDATA, AUX, IPL overlay, and directional CPU I/O.
- Model CPU/APU port clear and same-cycle collision rules on the shared timeline
  contract supplied by A30; until then, isolate the behavior behind functions
  that accept an explicit access clock.
- Separate SLEEP and STOP state and wake behavior.
- Audit all SPC700 instructions for cycle count, flags, and ordered bus accesses,
  prioritizing the failures exposed by `spc_smp`, `spc_timer`, and
  `spc_mem_access_times`.
- Add configurable deterministic power-on initialization for tests while leaving
  room for a hardware-like randomized/undefined-RAM option.

Acceptance criteria:

- All 256 opcode bytes have table-driven cycle/flag coverage, and each memory
  form records its ordered reads/writes with cycle offsets.
- Timer and MMIO tests cover boundary writes and adjacent-cycle collisions.
- The finite timer and memory-access Blargg tests reach success when fixtures
  are installed.
- Fragmented versus batched SPC execution remains equivalent.

Suggested agent prompt:

> Implement A10 from `APU_IMPROVEMENT_PLAN.md`. Own only `spc700.ex` and focused
> SPC700/S-SMP tests. Preserve the existing APU event API; coordinate any needed
> API change with the A30 integrator instead of editing `apu.ex` or `dsp.ex`.

### A20 — Clocked scalar DSP skeleton and arithmetic contract

**Depends on:** A00  
**Owns:** top-level `dsp.ex`, new DSP clock/state modules, arithmetic tests

Refactor the atomic per-sample renderer into a clockable scalar state machine
without yet adding echo, noise, or PMON. This package defines the interfaces
that later DSP agents use.

Deliverables:

- An explicit 0–31 DSP phase, sample counter, register latches, per-voice
  pipeline state, and deterministic reset state.
- `clock/2` or equivalent as the correctness primitive; block rendering should
  be a loop or optimized wrapper over identical state transitions.
- A small internal module boundary for voice, noise/modulation, echo, and final
  mixer stages, with immutable inputs/outputs documented in module docs.
- Hardware-style signed arithmetic helpers, including arithmetic shifts,
  wrapping where required, and saturation at each specified mixer stage.
- Correct per-voice accumulation/clamping order rather than one final clamp.
- Compatibility adapters so callers and existing tests can migrate in small
  steps rather than requiring an all-at-once rewrite.

Acceptance criteria:

- One sample advanced as 32 clocks equals the same sample advanced as a block.
- Chunk sizes of 1, 31, 32, 33, and a normal frame batch yield identical final
  state and PCM.
- Negative odd values prove arithmetic-right-shift behavior.
- Tests prove main and echo accumulation saturate at the hardware stage.
- Existing implemented features have unchanged output unless a golden vector
  demonstrates that the old output was inaccurate.

Suggested agent prompt:

> Implement A20 from `APU_IMPROVEMENT_PLAN.md`. You are the sole owner of the
> top-level DSP refactor. Freeze and document extension interfaces for A40,
> A50, and A60. Do not implement those feature packages yet.

### A30 — Shared SPC/DSP timeline and RAM visibility

**Depends on:** A20; coordinate with A10  
**Owns:** `apu.ex`, top-level DSP integration, APU timeline tests

Replace “run SPC, then replay writes against final RAM” with one ordered APU
timeline. The SPC and DSP advance from an explicit common clock/phase origin.

Deliverables:

- Interleave SPC bus accesses, DSP clocks, register writes/reads, and RAM access
  at their actual timestamps.
- DSPDATA reads observe the DSP state available at that cycle, not state from
  the start or end of the batch.
- BRR and future echo reads observe only RAM writes that have already occurred.
- DSP RAM writeback becomes visible to the SPC at the correct time.
- CPU-to-APU and APU-to-CPU port events retain direction and their collision
  policy on the same timeline.
- DMA writes to `$2140-$2143` flush/advance the APU per bus access rather than
  collapsing a burst to one final value.
- Save state records enough clock/phase/event state to resume bit-exactly.

Acceptance criteria:

- Running N clocks in one call or arbitrarily partitioned calls produces the
  same APU state, RAM, ports, and PCM.
- Tests cover a RAM write immediately before and after a DSP BRR/echo read.
- Tests cover DSP register read/write collisions at relevant pipeline phases.
- Save/restore in every DSP phase resumes with identical subsequent state.
- No unbounded event queue grows during normal frame execution.

Suggested agent prompt:

> Implement A30 from `APU_IMPROVEMENT_PLAN.md` after A20 lands. Be the sole
> integrator for `apu.ex` and top-level `dsp.ex`. Coordinate access-clock hooks
> with A10; do not absorb unrelated SPC instruction fixes.

### A40 — Voice pipeline, BRR fetch, keying, and live registers

**Depends on:** A20 and A30 interfaces  
**Owns:** extracted voice/BRR modules and focused tests; integration is by A30's
owner or a designated DSP integrator

Deliverables:

- Phase-correct BRR header/data fetch, nibble decode, filters, history, END and
  loop behavior.
- Phase-correct pitch counter, Gaussian interpolation, sample output, envelope
  update, and voice accumulation.
- Exact KON/KOFF latching, KON delay, KON priority, release, ENDX set/clear, and
  collision timing.
- Live ENVX and OUTX values with the correct update/read phases.
- Accurate FLG reset and mute effects on internal state, not only final output.

Acceptance criteria:

- Clock-indexed vectors cover every BRR filter, range edge, loop/end transition,
  and KON/KOFF/ENDX collision class.
- ENVX and OUTX reads change on the documented phases.
- Voice state matches the selected reference implementation across randomized
  legal register/RAM vectors for a bounded number of clocks.
- No eager whole-block decode remains in the authentic path if it changes RAM
  visibility or phase behavior.

Suggested agent prompt:

> Implement A40 from `APU_IMPROVEMENT_PLAN.md` against the frozen A20 voice
> interface. Keep feature code in the assigned modules and provide integration
> hooks plus tests; do not independently rewrite `apu.ex` or top-level `dsp.ex`.

### A50 — Noise generator and pitch modulation

**Depends on:** A20 and A30 interfaces  
**Owns:** extracted noise/modulation modules and focused tests

Deliverables:

- The 15-bit S-DSP noise LFSR and all FLG low-five-bit clock rates.
- NON voice selection at the correct pipeline phase.
- PMON for voices 1–7 using the previous voice's output with the hardware
  signed arithmetic and pitch limits; voice 0 must never be modulated.
- Correct ordering when the source voice uses noise or is keyed/reset.

Acceptance criteria:

- Golden sequences cover every noise rate and reset/seed behavior.
- PMON boundary tests cover negative source output, maximum pitch, voice 0,
  and chained modulation across several voices.
- Feature-disabled output and state remain identical to the pre-package golden
  vectors.

Suggested agent prompt:

> Implement A50 from `APU_IMPROVEMENT_PLAN.md` using the A20 extension API.
> Own only noise/modulation modules and their tests. Hand integration changes to
> the designated DSP integrator.

### A60 — Echo RAM, feedback, and eight-tap FIR

**Depends on:** A20 and A30 interfaces  
**Owns:** extracted echo module and focused tests

Deliverables:

- EVOLL/EVOLR, EFB, EON, ESA, EDL, and all eight signed FIR coefficients.
- Eight-sample stereo history with the S-DSP's intermediate truncation,
  wrapping, and saturation rules.
- Echo ring address/length behavior, including EDL changes and wrap.
- Timed echo RAM reads and writeback through the A30 shared-memory interface.
- FLG echo-write disable semantics while continuing the required reads and
  internal processing.
- Correct main-plus-echo final mixing order.

Acceptance criteria:

- Impulse-response vectors validate tap order, channel history, arithmetic, and
  ring wrap.
- Tests cover maximum/minimum feedback and volume, writes disabled, and ESA/EDL
  changes while echo is running.
- SPC/DSP RAM collision tests demonstrate correct before/after visibility.
- Echo-off behavior remains identical to the established scalar golden output.

Suggested agent prompt:

> Implement A60 from `APU_IMPROVEMENT_PLAN.md` against the frozen echo and RAM
> interfaces. Keep changes in the echo module and focused tests; coordinate the
> small top-level integration patch with the A30 owner.

### A70 — Accuracy integration and conformance gate

**Depends on:** A10, A30, A40, A50, and A60  
**Owns:** integration fixes, conformance expectations, status documentation

Deliverables:

- Integrate all scalar packages and resolve behavior only by trace/reference
  evidence, not by whichever branch landed first.
- Run focused vectors, randomized differential tests, installed Blargg tests,
  save-state tests, and the full suite.
- Extend long-running conformance bounds where needed so `spc_dsp6` and
  `spc_smp` can reach a positive result instead of merely avoiding failure.
- Update `IMPLEMENTATION_STATUS.md` and the SNES README to describe measured
  coverage and remaining limitations.
- Record performance for ordinary gameplay batches before and after the clocked
  core so optimization work starts from a measured profile.

Accuracy gate required before enhancement work:

- no known failures in the locally installed Blargg SPC suite;
- all original focused vectors pass in scalar mode;
- chunking and save/restore are bit-exact at every DSP phase;
- at least two real-game audio captures have stable hashes and no newly
  introduced underruns;
- every remaining approximation is listed explicitly in
  `IMPLEMENTATION_STATUS.md` with a test or issue reference.

Conformance command when fixtures are installed:

```console
mix test --include conformance test/beamicom/snes/conformance_rom_test.exs
```

Suggested agent prompt:

> Perform A70 from `APU_IMPROVEMENT_PLAN.md`. Integrate the completed accuracy
> packages, run every stated gate, and update documentation from observed
> results. Do not begin enhanced audio work or loosen failing expectations.

## Nx work packages

### A80 — Bit-exact authentic Nx renderer

**Depends on:** A70 gate  
**Owns:** `nx/dsp_renderer.ex`, Nx-focused tests and benchmarks

Move only proven batchable DSP operations into `Nx.Defn`. Exact clock and
register control remains scalar. Prefer a hybrid renderer when recurrent or
event-heavy work cannot be profitably compiled.

Deliverables:

- Tensor layouts for voices, samples, buses, and state with explicit signed
  widths and clamp points.
- Nx kernels for profitable spans of authentic synthesis/mixing, including
  voice and echo work only where scalar/Nx parity can be demonstrated.
- Event-aware chunk splitting: no kernel may cross a DSP write, relevant RAM
  mutation, key event, or other accuracy boundary unnoticed.
- Replace the fixed 4,096-frame full-synthesis threshold with measured backend
  selection or an explained retained threshold.
- Backend cache/warmup behavior that does not alter emulated state.
- Native fallback for short batches, unsupported backends, or unavailable Nx.

Acceptance criteria:

- Scalar and Nx authentic modes match PCM, registers, RAM, and resumed state
  bit-for-bit for the entire A00 corpus and randomized event streams.
- Parity covers awkward chunk sizes and boundaries, not only 4,096-frame calls.
- Benchmarks report compile cost separately from steady-state throughput and
  show whether the normal roughly frame-sized workload benefits.
- Save states are renderer-independent: scalar can resume an Nx state and vice
  versa.

Suggested agent prompt:

> Implement A80 from `APU_IMPROVEMENT_PLAN.md` only after A70 passes. Optimize
> the authentic renderer with Nx while treating scalar state and PCM as the
> bit-exact oracle. Include normal-batch benchmarks, not only large synthetic
> batches.

### E10 — Experimental Nx voice/bus enhancement

**Depends on:** A70; preferably A80  
**Owns:** new enhanced renderer modules and tests; no authentic DSP changes

This is the requested “modernized SPC700 sound” experiment. It should receive
structured per-voice and bus data from the accurate DSP boundary, not merely
process the final `AudioSink` stream. That allows the effect to behave like an
optional core capability analogous to enhanced graphics rendering.

Start with one conservative preset and expose parameters only after it is
stable. Candidate stages, all suited to batched Nx kernels, are:

1. DC blocking and conservative headroom management.
2. Per-voice transient shaping or envelope-aware dynamics using the authentic
   envelope/key state as side information.
3. Low-frequency enhancement using a low shelf plus optional synthesized
   harmonics, with strict excursion/headroom limits rather than indiscriminate
   bass boost.
4. Optional bus compression/soft limiting after voice and echo buses are
   recombined.
5. Optional enhanced echo width/clarity while retaining a dry authentic path.

Architectural contract:

- modes are explicit, for example `:authentic` and `{:enhanced, preset}`;
- authentic samples are always obtainable from the same input/state;
- effect history, preset version, parameters, and bypass state are deterministic
  and included in save state;
- bypass introduces no gain change or hidden filtering;
- effect latency is fixed and declared; the video/audio synchronizer accounts
  for it rather than silently drifting;
- kernels accept batches but split at mode/parameter changes;
- no preset is marketed as hardware accurate.

Acceptance criteria:

- Authentic mode remains bit-identical to the A70/A80 oracle.
- Bypass is bit-identical or, if a fixed latency buffer is unavoidable,
  bit-identical after the documented delay.
- Preset output is deterministic across native CPU and supported Nx backends
  within an explicitly documented numeric tolerance.
- Silence stays silent; DC, maximum-level, impulse, bass-sweep, and rapid-keying
  torture cases remain bounded and free of NaN/Inf.
- Loudness-matched listening captures are produced for at least two contrasting
  games and compared without clipping.
- CPU time, Nx compile time, steady-state latency, and allocations are measured
  at normal gameplay batch sizes.

Suggested agent prompt:

> Implement E10 from `APU_IMPROVEMENT_PLAN.md` as a new opt-in Nx enhanced
> renderer. Consume accurate per-voice/bus signals, preserve authentic output,
> begin with one conservative preset, and include deterministic save state,
> safety vectors, listening captures, and normal-workload benchmarks.

### E20 — Enhancement product gate

**Depends on:** E10  
**Owns:** public configuration, documentation, save-state migration, final QA

Deliverables:

- One documented opt-in setting with authentic mode still the default.
- Capability detection and graceful native/authentic fallback.
- Versioned preset identifiers so tuning changes do not silently change old
  save states or reproducible captures.
- A/B capture tooling with loudness matching and a clear enhancement indicator.
- Performance budgets for real-time native CPU and supported Nx backends.
- A short warning that enhanced audio intentionally differs from SNES hardware.

Acceptance criteria:

- Loading an authentic save never silently enables enhancement.
- Loading an enhanced save on a system without Nx produces a clear fallback or
  error according to the documented policy.
- Rapid toggling does not click, corrupt DSP state, or desynchronize audio.
- The full test suite and authentic conformance gate still pass.

Suggested agent prompt:

> Complete E20 from `APU_IMPROVEMENT_PLAN.md`. Productize the accepted E10
> preset as opt-in, preserve authentic defaults and save compatibility, and
> document fallback, latency, performance, and intentional inaccuracy.

## Recommended spawn waves

Do not spawn every package at once. Use these waves to preserve the central
architecture and avoid merge churn.

### Wave 1 — Baseline and independent SMP work

- Agent 1: A00 reference harness.
- Agent 2: A10 SPC700/S-SMP correctness, initially using an explicit access
  clock abstraction rather than modifying APU orchestration.
- Agent 3: A20 clocked DSP skeleton after A00 establishes vector conventions.

Merge A00 first. Merge A20 only after its extension interfaces are documented.

### Wave 2 — Timeline

- One integration agent: A30, incorporating A10's access-clock hooks.

Keep this wave single-writer for `apu.ex` and top-level `dsp.ex`.

### Wave 3 — Independent DSP features

- Agent 1: A40 voice/BRR/key pipeline.
- Agent 2: A50 noise and PMON.
- Agent 3: A60 echo and FIR.
- The A30 owner or a new integration agent applies the small top-level hooks.

Feature agents should rebase on the same A20/A30 interface commit and avoid
editing central orchestration files.

### Wave 4 — Accuracy gate and authentic acceleration

- One agent: A70 accuracy integration and documentation.
- After A70 passes, one agent: A80 authentic Nx parity and benchmarks.

### Wave 5 — Deliberate enhancement experiment

- One agent: E10 prototype and evaluation artifacts.
- After listening, correctness, and performance review, one agent: E20 public
  configuration and compatibility work.

## Merge checklist for every package

- [ ] Dependency packages are merged at the expected commit.
- [ ] Assigned production-file boundaries were respected.
- [ ] The bug or behavior has a focused pre-change test/vector.
- [ ] Scalar authentic output changes are justified by a reference trace.
- [ ] Chunked and unchunked execution agree.
- [ ] Save-state compatibility is tested when state shape changes.
- [ ] Native/Nx authentic parity is retained where applicable.
- [ ] Formatting, warnings-as-errors, focused tests, and the full suite pass.
- [ ] Conformance fixture skips are reported rather than described as passes.
- [ ] Status documentation distinguishes implemented, partial, and validated.
- [ ] Performance claims include normal gameplay batch sizes.

## Primary technical references

Use primary documentation and source-level reference implementations to settle
observable behavior. Keep the implementation original and cite the exact
behavior being tested in comments or fixture documentation.

- [Nintendo SNES development manual, Book I](https://floating.muncher.se/bot/manual/book1_text.pdf)
- [SNESdev S-DSP register reference](https://snes.nesdev.org/wiki/S-DSP_registers)
- [Blargg's `snes_spc` reference emulator](https://github.com/blarggs-audio-libraries/snes_spc)
- [ares SFC DSP implementation](https://github.com/ares-emulator/ares/tree/master/ares/sfc/dsp)
- [`spc_dsp6`/`spc_smp` fixture provenance](test/fixtures/snes_conformance/blargg-spc-6/README.md)
