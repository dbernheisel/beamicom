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

## Local installation

Download the four unmodified `.sfc` files named in `SHA256SUMS` from the source
mirror at the pinned commit above. Copy them into this directory without
renaming them, then verify their bytes before running the emulator:

```console
cd test/fixtures/snes_conformance/blargg-spc-6
shasum -a 256 -c SHA256SUMS
```

No download command is embedded here because the upstream repository does not
state a license for these binaries. Installing them is an explicit local
choice; `.gitignore` prevents accidental commits of the ROMs.

Run the fixture-status tests with trace output to get one unambiguous result per
ROM:

```console
mix test --trace test/beamicom/snes/blargg_spc_fixture_status_test.exs
```

- `pass` means the fixture exists and its SHA-256 matches.
- `fail` means the installed bytes do not match the recorded upstream hash.
- `skipped: fixture missing` means that ROM was not installed; it is not a
  conformance pass.

The tagged checks boot all four ROMs, exercise both processors, and verify that
none reaches Blargg's red failure screen through the bounded 120-frame
checkpoint. They also assert the explicit blue success screen for the finite
timer and memory-access suites; the longer DSP and SMP stress suites are still
running at the bounded checkpoint.
