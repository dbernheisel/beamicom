# Beamicom Nx PPU renderer

This optional adapter leaves the NES CPU, memory, mapper, PPU timing, and APU in
the dependency-free `beamicom` application. At each visible scanline the native
PPU resolves mapper-sensitive tile rows, evaluates sprites, and applies status
side effects. At frame completion this adapter composes all 240 by 256 palette
addresses in one EXLA CPU call.

Configure it before loading a console:

```elixir
Application.put_env(:beamicom, :ppu_renderer, BeamicomNx.NES.PPURenderer)
```

The benchmark task accepts the same choice when run from this project:

```console
mix nes.bench ../beamicom/roms/castlevania3.nes --seconds 15 --renderer nx
```

The native renderer remains the default and requires neither Nx nor EXLA.

## Current result

The 902-frame (15.009 emulated seconds) Castlevania III run is exact: the native
and Nx paths produced the same RGB and audio SHA-256 hashes. On the EXLA CPU
client used for the initial measurement, pure native emulation ran at 88.06 FPS
and the initial palette-address-only Nx adapter at 79.14 FPS. The narrow kernel
does not improve single-instance CPU throughput by itself.

When the benchmark includes the three RGB consumers used by Scenic, V4L2, and
streaming, native runs at 66.54 FPS and the shared Nx RGB result runs at 77.83
FPS. Deferring palette expansion and doing it once in the frame kernel therefore
improves this three-sink workload by 17.0%.

The optional `nx_atlas` renderer expands immutable CHR ROM into a resident tile
atlas at cartridge load. It reaches 79.32 FPS during Castlevania III's first five
seconds versus 76.54 FPS for byte decoding, but over the full fifteen seconds it
runs at 75.31 FPS versus 77.83 FPS. The access pattern changes with the scene, so
the byte renderer remains the default while the atlas path is available for GPU
and batched-instance measurements.

PPU status timing and mapper-visible effects remain native even when visual work
moves into the adapter. CHR RAM and latch-driven cartridges automatically use
the byte-capture path.
