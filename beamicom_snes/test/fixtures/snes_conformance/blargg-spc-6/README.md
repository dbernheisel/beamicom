# Blargg SPC test ROMs

These unmodified ROM images may be installed locally for automated SNES
S-SMP/S-DSP compatibility testing. ROM binaries are intentionally ignored by
Git; this directory retains their provenance and expected hashes.

## Attribution and provenance

- Author: Shay Green (Blargg)
- Suite: the sixth and final known work-in-progress SPC test-ROM bundle
- Source mirror: <https://github.com/rmstdope/snes-test-roms/tree/master/blargg-spc-6>
- Source mirror commit: `17b401c2695b54f2dff35e0bca6995217181f100`
- Historical source: <https://forums.nesdev.org/viewtopic.php?t=18005>
- Retrieved: 2026-09-14

The upstream collection does not include a top-level license or a separate
license for these four binary ROMs. They are retained here with explicit
authorship and provenance for conformance testing. Do not represent them as
Beamicom-authored ROMs.

## Contents

- `spc_dsp6.sfc`: S-DSP synthesis, KON/KOFF, ENDX, BRR, envelope, echo, and
  pipeline-order tests.
- `spc_smp.sfc`: SPC700 instructions and timing, S-SMP registers, timers, and
  IPL tests.
- `spc_timer.sfc`: focused S-SMP timer behavior.
- `spc_mem_access_times.sfc`: focused SPC700 memory-access timing.

Integrity hashes are recorded in `SHA256SUMS`. The normal test suite performs
a short boot/progress smoke test. Longer checks are tagged `:conformance` and
can be run with:

```console
mix test --include conformance test/beamicom/snes/conformance_rom_test.exs
```

The conformance checks intentionally become red while an emulation defect is
present. At the time of vendoring, the timer and memory-access ROMs reach their
red failure screens; the DSP and SMP suites are still running at the bounded
120-frame checkpoint.
