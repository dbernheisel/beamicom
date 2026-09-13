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

Add the package to a client and opt in before loading a machine:

```elixir
{:beamicom_gbc_nx, path: "../beamicom_gbc_nx"}

Beamicom.GB.Nx.enable()
```

Select full event-block synthesis explicitly:

```elixir
Beamicom.GB.Nx.enable(apu_renderer: Beamicom.GB.Nx.APUSynthRenderer)
```

To opt in automatically before the client supervision tree starts:

```elixir
config :beamicom_gbc_nx, auto_enable: true
```

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
| native | native | 46.90 | — |
| frame-wide Nx | block Nx | 45.59 | -2.8% |
| frame-wide Nx | event-synthesis Nx | 44.55 | -5.0% |

Concurrent resolution recovers much of the deeper kernels' call overhead, but
the result still cannot accelerate this
single-instance workload because CPU and bus execution dominate while native
PPU/APU work is already a small fraction of the frame. Automatic activation
therefore remains disabled. The raw-row and event-block boundaries are intended
for larger kernels and future leading-axis batching without slowing clients
that use the native core.
