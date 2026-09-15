# NES AOT experiment plan

## Ground rules

- `Beamicom.NES.CPU.step/2` remains the behavioral oracle. The first executable
  milestone is a side-by-side equivalence harness; generated execution is not
  wired into `Console.step/1` until that harness is green.
- Existing public signatures and the framebuffer contract stay unchanged. New
  modules may expose new opt-in APIs. Any change to an existing public function
  signature requires approval first.
- The generated CPU state keeps the packed `P` byte. This matches `%CPU{}`
  exactly, makes PHP/PLP/BRK/RTI comparisons direct, and avoids seven booleans
  crossing every block boundary.
- Nx is used only for frame-parallel PPU/APU synthesis. The 6502 path is ordinary
  generated Elixir compiled to BEAM.

## Module layout and delivery order

### 1. Oracle and static recompiler

1. `Beamicom.NES.Recompiler.Equivalence`
   - Clone a starting console, run one interpreter instruction and one compiled
     instruction/block, and compare A/X/Y/SP/PC/P, interrupt latches, total
     cycles, RAM/WRAM, and observable bus/PPU/APU state.
   - Include deterministic mismatch reports and fixture-ROM tests before adding
     native instruction implementations.
2. `Beamicom.NES.Recompiler.Opcode`
   - One package-owned opcode metadata table shared by discovery/codegen tests.
     Initially validate it exhaustively against interpreter behavior rather than
     changing the interpreter's private `decode/1` API.
3. `Beamicom.NES.Recompiler.Discovery` / `MMC5Discovery`
   - Mapper-0 CPU-address-to-PRG translation.
   - Recursive descent from NMI/reset/IRQ vectors through conditional branches,
     `JMP abs`, and `JSR`; terminate blocks at control-flow instructions and at
     already discovered entries.
   - `JMP ind`, `RTS`, `RTI`, `BRK`, invalid opcodes, and ROM exits terminate the
     static block and use dynamic dispatch/fallback.
   - MMC5 release builds collect bank signatures and dynamic roots under the
     interpreter, then recursively descend only through instruction identities
     observed under each signature. Unknown signatures and executable PRG-RAM
     are mandatory fallbacks.
4. `Beamicom.NES.Recompiler.Generator`
   - Generate one hash-named module per mapper-0 PRG image with `block_xxxx/2`
     functions, a pattern-matched `dispatch/2`, and tail calls for known direct
     successors.
   - First generated backend delegates individual instruction semantics to the
     oracle-compatible runtime. Replace opcode families incrementally, keeping
     the equivalence suite green after each family.
5. `Beamicom.NES.Recompiler.Runtime`
   - State conversion, dynamic dispatch, interpreter fallback, memory helpers,
     cycle/interrupt boundary handling, frame-budget yield, and write logging.
   - Generated execution copies the initial 2 KiB binary RAM into `:atomics`
     once and retains that store across blocks and interpreter fallbacks.
     PPU/APU/controller/mapper accesses continue through `Bus.read/2` and
     `Bus.write/3`; equivalence and persistence boundaries use a stable binary
     snapshot.
6. `Mix.Tasks.Nes.Recompile` and `Mix.Tasks.Nes.RecompileBench`
   - Compile/cache a ROM module and report interpreter/recompiled throughput,
     static coverage, fallback counts, and speedup.

### 2. Nx frame synthesizer

The repository already has independent Nx PPU and APU block renderers. Extend
and test those rather than create a second rendering stack:

1. Background: factor a stable per-frame tensor entry point from
   `Beamicom.NES.Nx.PPURenderer`, accepting fixed-shape VRAM/palette/atlas and a
   padded scanline write timeline.
2. Sprites: retain native timing-visible sprite-zero behavior until a tested
   `[240][64]` in-range mask, `Nx.cumulative_sum/2` eight-sprite limiter,
   overflow result, and priority overlay match it.
3. APU: `Nx.FrameAPURenderer` captures the native CPU-timed DMC DAC lane at
   192 kHz, evaluates 2A03 and MMC5 oscillator state in `Nx.BlockAPU`, and uses a
   33-tap windowed-sinc `Nx.conv/3` pass to return 800 s16 samples at 48 kHz.
   The existing 44.1 kHz renderer remains the default.
4. Optional presentation: compose palette expansion and the existing Blargg
   NTSC convolution renderer behind a flag while always retaining native
   `u8[240][256]` palette-address pixels.
5. `Beamicom.NES.Nx.FrameSynthesizer`: one compiled defn called once per frame.
   Donate only consumed persistent buffers with a same-shaped successor output;
   compile and live arguments must carry identical donation marks.
6. `Mix.Tasks.Nes.DumpFrameExecutable` plus a boot loader: dump the platform-
   specific EXLA executable at release build time, load at boot, and compile on
   missing/incompatible dumps.
7. Benchmarks: synchronized wall time, exact host-to-device byte accounting, and
   EXLA allocation-log evidence for donation.

## Installed API audit (Nx 1.0.0 / EXLA 1.0.0)

- `Nx.donatable/1` recursively marks tensors; `Nx.to_template/1` preserves the
  mark. `Nx.Defn.compile/3` rejects a live argument whose donation mark differs
  from its template.
- `EXLA.Executable.dump/1` returns a serializable map.
  `EXLA.Executable.load/2` is called as `load(client, dumped_map)`.
- `EXLA.Defn.Disk` is present but `@moduledoc false`; it is an internal cache
  implementation, so production code should not depend on it directly.
- `Nx.Defn.Kernel.while/3` supports generator `unroll: true` or a positive batch
  size. `Nx.put_slice/3`, `Nx.take/3`, `Nx.cumulative_sum/2`, and `Nx.conv/3`
  are present in the installed sources. Concrete shapes/options will be checked
  against these sources again at each implementation site.

## Open questions / discovered constraints

1. `roms/castlevania3.nes` declares NES 2.0 mapper 5 (MMC5), not mapper 0. Its
   measured hot set stabilizes at seven PRG signatures and 1,836 instruction
   identities over one million interpreted instructions. Generated dispatch now
   keys on `{PC, four PRG offsets, PRG-RAM window mask}`. A mapping is checked at
   block entry and after memory-writing opcodes; unknown states fall back.
2. "BeamAsm" is not currently a dependency or module in this umbrella. The safe
   first implementation generates quoted Elixir and uses `Module.create/3`,
   which invokes the Elixir/BEAM compiler. Direct use of Erlang compiler-internal
   `:beam_asm` would need a separately specified, OTP-version-pinned IR contract.
3. The requested frame input is state plus register logs, while the existing PPU
   captures fetch-resolved scanline descriptions to preserve mapper behavior and
   timing-visible effects. For mapper 5, raw 2 KB VRAM plus a fixed CHR atlas is
   insufficient (banked CHR, ExRAM/extended attributes, split screen). The first
   exact synthesizer should keep the richer existing scanline contract; a strict
   raw-state/log contract can initially be mapper-0-only.
4. The 48 kHz host contract is opt-in through `BEAMICOM_AUDIO_48=1`; public
   function arities were preserved. `FrameAPUExecutable` has a platform-specific
   release dump/load path and an in-memory compile fallback. The current fixed
   frame buffer holds the last 192 kHz value across the short NTSC tail, so it is
   a fixed 800-sample/nominal-60-Hz contract rather than a fractional-rate audio
   clock with cross-frame FIR overlap.
5. The supplied Castlevania III image enables MMC5 expansion audio but did not
   touch DMC during a one-million-instruction trace. DMC is therefore covered by
   an active synthetic timing/render test, not claimed as ROM benchmark coverage.
   Native DMC still preloads each sample and does not model per-byte DMA stalls or
   mid-sample PRG bank switching.

## Measured expansion checkpoint

- CPU-only, one million Castlevania III instructions: seven MMC5 signatures,
  1,836 static identities, 12 fallbacks (0.0012%). The generated path is still
  slower because instruction semantics call the shared oracle core: 0.67x the
  interpreter after static-operand specialization. This is not yet a speed win.
- A 10,000-transition Castlevania III differential run matched A/X/Y/SP/P/PC,
  interrupt latches, cycles, RAM, WRAM, mapper state, and PRG mappings exactly.
- End-to-end over 61 warmed frames with Nx MMC5 video and the 48 kHz audio graph:
  interpreter 75.13 FPS versus AOT 70.82 FPS (0.943x), with identical video and
  audio SHA-256 hashes. The profile took 1.740 s and generated-module compilation
  took 13.163 s. The measured 0.00214% fallback rate is not the bottleneck.
- EXLA frame audio, 100 calls with active DMC and MMC5: mean 1.364 ms, p50
  1.268 ms, p95 1.987 ms, p99 2.242 ms; 50,696 host-to-device bytes and 1,600
  device-to-host bytes per call.
- Castlevania's atlas-mode video inputs add 53,746 host-to-device bytes and its
  palette-index plus RGB outputs add 245,760 device-to-host bytes, for 104,442
  combined host-to-device bytes per complete frame call.
- XLA's buffer-assignment dump reports 98,112 total bytes and an
  `input_output_alias` entry for every one of the 116 donated resident APU/FIR
  leaves. The two 4,096-sample per-frame input lanes remain ordinary parameter
  allocations, as expected.

## Mutable-RAM / hot-semantic checkpoint

- The AOT console now owns persistent `:atomics` CPU RAM. Castlevania's first
  million instructions are dominated by zero-page traffic: `STA zp`, `LDA zp`,
  `ADC zp`, and `INC zp` alone account for 467,108 instructions in the captured
  trace. Generated fallback remains valid because the interpreter bus supports
  both RAM representations. The equivalence harness always snapshots atomics to
  a fresh binary so shared mutable state cannot hide a mismatch.
- `CPU.step_static/6` now has exact specialized clauses for the dominant
  zero-page, immediate, implied, accumulator, branch, absolute/indexed,
  JSR/RTS, and load/store paths. They bypass generic address/operation dispatch,
  embed immediate values, access proven RAM/stack addresses directly, and keep
  the oracle's pre-access/post-access PPU timing and interrupt checks. Remaining
  operations still use the generic interpreter semantic path.
- A fresh 10,000-transition Castlevania III differential run passed. The
  million-instruction AOT rate rose from about 671k IPS at the original
  checkpoint to 764k IPS here; the latest single-run ratio was 0.773x because
  its interpreter sample reached 989k IPS. CPU-only AOT is therefore still a
  regression.
- Three warmed 61-frame end-to-end samples with MMC5 video and 48 kHz EXLA
  audio measured 1.049x, 1.013x, and 1.000x interpreter wall time (median
  1.013x). Video/audio hashes matched in every run, fallback remained 12 of
  561,896 instructions, and generated-module compilation was 12.95-13.08 s.
  This is break-even to a small gain, not yet a compelling speedup.
- An attempted local helper injection into each generated module was rejected:
  under Elixir 1.20 its nested generated block observed stale state bindings and
  yielded after one instruction. The differential tests caught it. Direct
  per-block semantics remain the next architectural step, but must use explicit
  state threading rather than nested hygienic quote rebinding.

## Direct generated-semantics checkpoint

- Generated blocks no longer call or depend on `CPU.step_static/6`; that
  function and its private static address resolver have been removed. The new
  `Recompiler.Semantics.step/6` macro receives the block's CPU and bus bindings
  explicitly and expands the hot zero-page, immediate, implied, accumulator,
  branch, absolute/indexed, JSR/RTS, load, and store semantics into the generated
  ROM module. Static instructions not yet lowered call the interpreter oracle's
  `CPU.step/2` directly.
- The exact timing envelope is deliberately shared with the interpreter through
  the small `CPU.aot_prepare/5` and `CPU.aot_complete/7` APIs. This preserves the
  pre-access/final-cycle PPU split, NMI/IRQ recognition, APU/mapper flushing, DMA
  stalls, and cycle count while separating timing from the generated opcode
  semantics.
- On Castlevania III's one-million-instruction profile, 1,701 of 1,836 static
  identities are directly lowered (92.65%), accounting for 975,436 executed
  instructions (97.5436%). The 10,000-transition differential trace passed, as
  did all 152 native tests and the 38-test Nx/EXLA suite (4 platform skips).
- CPU-only performance remains a regression: a 200,000-instruction sample ran
  at 790,873 IPS versus 1,046,578 IPS for the interpreter (0.756x). Generated
  module compilation also increased to 28.6 seconds in that sample because the
  expanded block bodies are larger.
- Three 61-frame MMC5 + 48 kHz EXLA samples measured 1.045x, 1.063x, and 1.114x
  end-to-end speedup (median 1.063x). Every video/audio hash matched, with 12
  dynamic-dispatch fallbacks in 561,896 instructions. Compile times were 31.09,
  33.60, and 28.71 seconds (median 31.09 seconds). The direct semantics therefore
  buy a modest frame-level improvement but worsen load-time latency; with 97.54%
  weighted lowering, the remaining interpreter fallback is not the bottleneck.
  The next experiment should reduce the two cross-module timing-envelope calls
  per lowered instruction without weakening cycle/NMI/IRQ equivalence.

## Checkpoints

- C0: baseline tests and ROM/header report.
- C1: equivalence harness plus discovery tests, no runtime integration.
- C2: generated dispatch/fallback with 100% oracle equivalence.
- C3: instruction families migrated with coverage and RAM benchmark reports.
- C4: fixed-shape frame sub-defns tested independently.
- C5: composed/dumped executable, boot fallback, allocation and frame benchmarks.
