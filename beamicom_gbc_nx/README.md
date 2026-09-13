# Beamicom GBC Nx

Optional EXLA frame and audio renderers for `beamicom_gbc`, covering both DMG
and CGB execution. The dependency-free core keeps LCD timing and memory access
rules in Elixir. At each HBlank it records compact tile-plane rows and the first
ten selected objects. At VBlank one EXLA operation performs bit-plane expansion,
scroll and window selection, sprite composition, priority, and palette lookup
for all 144×160 pixels.

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

On the current EXLA CPU client, three 120-frame Link's Awakening DX runs gave
these medians with identical video and audio hashes:

| PPU | APU | FPS | Difference from native |
| --- | --- | ---: | ---: |
| native | block Elixir | 52.72 | — |
| frame-wide Nx | block Nx | 51.90 | -1.6% |

Moving deferred APU time into the compact bus state and skipping inactive
device work raised both current paths. The dependency-free core now uses its
Elixir block mixer by default, while the optional package selects the Nx block
mixer at compile time. Their matching hashes confirm the same output; on this
single-instance workload the Elixir path remains slightly faster. The raw-row
and event-block boundaries remain available for larger kernels and future
leading-axis batching.

CGB capture keeps hardware BGR555 palettes and deduplicates them per frame.
Link's Awakening used one palette snapshot across all 144 scanlines: the PPU
input fell from 53,568 to 26,192 bytes per frame, and the isolated EXLA PPU
boundary fell from roughly 116 ms to 79 ms over 120 frames. Runtime renderer
detection is compiled out of normal APU builds; it is enabled only by the Nx
cross-backend test configuration.
