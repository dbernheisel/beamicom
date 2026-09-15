# NESER Mode 7 conformance ROMs

These optional fixtures come from the zlib-licensed
[`neser-mode7-tests`](https://github.com/rmstdope/snes-test-roms/tree/17b401c2695b54f2dff35e0bca6995217181f100/neser-mode7-tests)
suite at commit `17b401c2695b54f2dff35e0bca6995217181f100`.

The eight ROMs cover the identity transform, scaling with all three
out-of-screen behaviors, rotation, horizontal and vertical flips, and mosaic.
The conformance tests compare frame 68's packed RGB24 output with framebuffer
CRCs approved against Mesen2 by the upstream NESER integration suite.

ROM binaries are intentionally excluded by the repository-wide `*.sfc` ignore
rule. Place the following upstream files beside this README to enable the tests:

- `m7-identity.sfc`
- `m7-scale-wrap.sfc`
- `m7-scale-color0.sfc`
- `m7-scale-tile0.sfc`
- `m7-rot30.sfc`
- `m7-flip-h.sfc`
- `m7-flip-v.sfc`
- `m7-mosaic.sfc`

Run them with:

```console
mix test --include conformance test/beamicom/snes/neser_mode7_conformance_rom_test.exs
```
