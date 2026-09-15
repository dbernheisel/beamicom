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
3. `Beamicom.NES.Recompiler.Discovery`
   - Mapper-0 CPU-address-to-PRG translation.
   - Recursive descent from NMI/reset/IRQ vectors through conditional branches,
     `JMP abs`, and `JSR`; terminate blocks at control-flow instructions and at
     already discovered entries.
   - `JMP ind`, `RTS`, `RTI`, `BRK`, invalid opcodes, and ROM exits terminate the
     static block and use dynamic dispatch/fallback.
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
   - Plain RAM is evaluated with `:atomics`; PPU/APU/controller/mapper accesses
     continue through `Bus.read/2` and `Bus.write/3`. Adoption waits for a
     reproducible `:atomics` versus binary-copy benchmark because the current bus
     and save-state design stores RAM as a binary.
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
3. APU: compose the existing timestamped `Nx.BlockAPU` path with fixed-capacity
   writes. Add the requested time-domain phase/cumulative-sum and windowed-sinc
   `Nx.conv/3` decimator only after waveform equivalence tests define the exact
   resampling contract (current output is 44.1 kHz; requested output is 48 kHz).
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

1. `roms/castlevania3.nes` declares NES 2.0 mapper 5 (MMC5), not mapper 0. It is
   suitable for measuring interpreter and Nx-frame behavior, and for measuring
   how completely fallback dominates, but it cannot exercise mapper-0 static
   PRG discovery because its CPU address mapping changes at runtime. Initial AOT
   equivalence/coverage therefore uses the checked-in mapper-0 conformance ROMs.
   Making Castlevania III itself statically recompiled is a separate mapper-5
   bank-specialization milestone.
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
4. Existing audio output and host capability are 44.1 kHz. Moving the public
   output contract to 48 kHz affects sinks and requires approval; until then a
   48 kHz synthesizer should be opt-in and converted at the integration edge.

## Checkpoints

- C0: baseline tests and ROM/header report.
- C1: equivalence harness plus discovery tests, no runtime integration.
- C2: generated dispatch/fallback with 100% oracle equivalence.
- C3: instruction families migrated with coverage and RAM benchmark reports.
- C4: fixed-shape frame sub-defns tested independently.
- C5: composed/dumped executable, boot fallback, allocation and frame benchmarks.
