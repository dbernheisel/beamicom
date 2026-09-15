# Gilyon SNES CPU test ROMs

These unmodified ROM images may be installed locally alongside the retained
test catalogs for automated 65C816 and SPC-700 instruction conformance testing.
ROM binaries are intentionally ignored by Git.

## Attribution and provenance

- Author: gilyon
- Upstream project: <https://github.com/gilyon/snes-tests>
- Upstream release: <https://github.com/gilyon/snes-tests/releases/tag/v1.4>
- Release tag commit: `5ecdf555da920f0bd7b157542141965a8120186d`
- Release archive SHA-256: `c3a39e15a9f3789fe143e54dfa035c988204576eafacf97df8ff3546a917c5e9`
- Retrieved: 2026-09-14
- License: MIT; the upstream license is retained in `LICENSE`

## Contents

- `cputest-basic.sfc`: 1,107 65C816 instruction cases, excluding unusual
  emulation-mode behavior.
- `cputest-full.sfc`: 1,610 65C816 instruction cases, including wrapping and
  emulation-mode edge cases.
- `spctest.sfc`: 1,368 SPC-700 instruction cases.
- `*-cases.txt`: upstream-generated inputs and expected results for diagnosing
  a reported hexadecimal test number.

The CPU suites intentionally omit STP and WAI. The SPC suite intentionally
omits SLEEP and STOP. These ROMs test instruction semantics rather than cycle
counts, interrupts, DSP behavior, or S-SMP timers.

Integrity hashes are recorded in `SHA256SUMS`. Normal tests verify the bytes
and perform bounded boot/progress checks. Full result assertions are tagged
`:conformance` and can be run with:

```console
mix test --include conformance test/beamicom/snes/gilyon_conformance_rom_test.exs
```

The result decoder reads the ROM's ASCII BG1 tilemap protocol and stops as
soon as it sees `Success` or `Failed`. All three tagged assertions currently
reach `Success` within their 240-frame bound.
