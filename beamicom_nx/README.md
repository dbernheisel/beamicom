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
and Nx paths produced the same video and audio SHA-256 hashes. On the EXLA CPU
client used for the initial measurement, native composition ran at 88.06 FPS and
the Nx adapter at 79.14 FPS. The narrow boundary is therefore correct and easy to
profile, but does not yet improve single-instance CPU throughput.

The next useful experiments are to keep a CHR tile atlas resident in the adapter
and to return an RGB frame from the same call, avoiding repeated palette expansion
in Scenic, V4L2, and streaming sinks. PPU status timing and mapper-visible effects
remain native even if more visual work moves into the adapter.
