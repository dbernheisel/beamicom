# Beamicom GBC Nx

Optional EXLA frame and audio renderers for `beamicom_gbc`, covering both DMG
and CGB execution. The dependency-free core keeps LCD timing and memory access
rules in Elixir. The renderer receives frame-start VRAM, OAM, and palette RAM,
nine control bytes per scanline, and accepted visible memory writes tagged with
the first line they affect. At VBlank one EXLA operation performs tile-map and
pattern lookup, evaluates all 40 sprites with the first-10 rule, expands bit
planes, and composes all 144×160 pixels.

The default Nx audio renderer batches the already resolved channel levels. The
package also contains `Beamicom.GB.Nx.APUSynthRenderer`, which accepts compact
control epochs and keeps pulse timers, wave position, noise LFSR, and sample
phase in EXLA across frames. It synthesizes every sample in an epoch as one
vector operation and is useful for further batching work, although it is slower
for one emulator on the current CPU client.

Add the package and select its renderers in the client's compile-time config:

```elixir
{:beamicom_gbc_nx, path: "../beamicom_gbc_nx"}

config :beamicom_gbc,
  ppu_renderer: Beamicom.GB.Nx.PPURenderer,
  apu_renderer: Beamicom.GB.Nx.APUBlockRenderer
```

Select full event-block synthesis explicitly:

```elixir
config :beamicom_gbc, apu_renderer: Beamicom.GB.Nx.APUSynthRenderer
```

Changing a renderer requires recompiling `beamicom_gbc`. Machine creation and
execution never query the application environment for a backend.

The default APU graph and the common static/visible-write PPU startup graphs are
compiled while the machine loads, before a host opens audio playback. Uncommon
PPU event shapes remain cached on first use; the shared runtime treats such a
compile as a clock discontinuity instead of emitting catch-up audio.

The core retains no Nx or EXLA dependency. PPU and APU programs resolve
concurrently at the host output boundary, and EXLA-backed audio state is copied
through the renderer's snapshot/restore callbacks for portable save states.

Compare implementations with the deterministic benchmark task:

```sh
mix gb.bench /path/to/game.gbc --frames 120 --repeats 3 \
  --renderer nx --audio-renderer nx_block

mix gb.bench /path/to/game.gbc --frames 120 --repeats 3 \
  --renderer nx --audio-renderer nx_synth
```

On the current EXLA CPU client, two warmed 60-frame runs of the bundled CGB
compatibility fixture gave these medians with identical video and audio hashes:

| PPU | APU | FPS | Difference from native |
| --- | --- | ---: | ---: |
| native | block Elixir | 96.61 | — |
| frame-wide Nx | block Nx | 75.23 | -22.1% |

The dependency-free core uses its Elixir block mixer by default, while the
optional package selects the Nx block mixer at compile time. Their matching
hashes confirm the same output. On this single-instance CPU workload, full tile
lookup and 40-sprite evaluation cost more in EXLA than the native scanline path;
the frame-wide graph is intended to support larger kernels and future
leading-axis batching. The shared bus avoids full timer/PPU dispatch when a
timer-off CPU cycle remains within the current LCD mode, and uses direct cycle
reads for ROM, WRAM, and HRAM; exact processing remains at every LCD boundary.

The base frame payload is about 18 KB: 16 KB VRAM, 160-byte OAM, 128-byte CGB
palette RAM, and 1,296 bytes of scanline controls. Each visible memory write adds
one compact event. Sparse timed reads overlay those events at lookup sites, so
the graph does not materialize a 144×16 KB copy of VRAM. Runtime renderer
detection is compiled out of normal PPU and APU builds; it is enabled only by
the Nx cross-backend test configuration.

`Beamicom.GB.Nx.PixelTransparency` ports Matt Akins'
[Pixel Transparency](https://github.com/mattakins/Pixel_Transparency) shader.
It treats bright pixels as translucent LCD cells over a textured backing and adds
subpixel modulation, polarizer tint, and static blurred shadows. Scenic exposes it
as `video_filter: :pixel_transparency`; direct callers can use
`PixelTransparency.filter/4` or the resident-tensor `filter_tensor/3`.
