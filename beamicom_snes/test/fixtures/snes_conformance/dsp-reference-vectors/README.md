# S-DSP reference vectors

The vectors in `test_helpers/dsp_reference_vectors.ex` are small, original
Beamicom fixtures. They contain only generated register values, RAM bytes, and
expected digests; no reference-emulator source or third-party ROM data is
copied into the project.

## Trace and reference format

`Beamicom.SNES.DSPTrace.run/2` applies each vector's ordered setup/actions and
returns a trace. A trace exposes:

- `pcm/1` for signed-16 little-endian stereo output;
- `read_register/2`, `read_voice/2`, and `read_ram/2` for direct inspection;
- `snapshot/2` for a portable map containing the chosen registers, voices, RAM
  bytes, timing, PCM, and DSP counters;
- `compare/3` for scalar/Nx or trusted-reference comparison.

A trusted emulator can be run separately with the same register/RAM bytes and
clock count. Convert its result into the map shape returned by `snapshot/2`,
then pass that map to `compare/3`. The first mismatch identifies its clock and
sample plus the PCM channel, register address, voice field, or RAM address.
This keeps the trust boundary at data produced by the reference rather than
embedding reference source in Beamicom.

## Golden hashes

Every active vector records separate PCM and state SHA-256 hashes. Hash input
includes all of the following identities:

- hash schema version;
- vector ID and vector version;
- renderer ID and renderer version.

Consequently, identical native and Nx data intentionally has different hashes.
Use `compare/3` to establish cross-renderer parity; use the hashes to detect
unexpected changes within one versioned renderer/vector pair. The state hash
uses Erlang's deterministic external-term encoding, which is stable within an
OTP major release. Reconfirm trusted output before updating a digest after an
OTP-major upgrade or intentional accuracy fix.

The echo, noise, and PMON vectors are active golden targets. They cover echo
RAM/FIR state, NON noise sequencing, and per-voice PMON state alongside the
voice and arithmetic vectors.

Run the focused harness with:

```console
mix test --trace test/beamicom/snes/dsp_reference_harness_test.exs
```
