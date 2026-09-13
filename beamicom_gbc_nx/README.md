# Beamicom GBC Nx

Optional EXLA frame and audio renderers for `beamicom_gbc`. The dependency-free core
keeps LCD timing, VRAM/OAM access, tile addressing, window state, and sprite
selection in Elixir. At VBlank this package composes sprite priority and
per-scanline DMG/CGB palettes across all 144×160 pixels in one EXLA call. The
block APU renderer converts a frame of channel levels, stereo routing, and
master volume to interleaved PCM in a second EXLA call.

Add the package to a client and opt in before loading a machine:

```elixir
{:beamicom_gbc_nx, path: "../beamicom_gbc_nx"}

Beamicom.GB.Nx.enable()
```

To opt in automatically before the client supervision tree starts:

```elixir
config :beamicom_gbc_nx, auto_enable: true
```

The core retains no Nx or EXLA dependency.

Compare implementations with the deterministic benchmark task:

```sh
mix gb.bench /path/to/game.gbc --frames 120 --repeats 3 \
  --renderer nx --audio-renderer nx_block
```

On the current EXLA CPU client, a single Link's Awakening DX instance remains
CPU/Bus-bound. Over three 120-frame runs the native median is 47.53 FPS and the
combined Nx median is 45.71 FPS, with identical video and PCM hashes. For that
reason automatic activation is disabled by default. The frame-sized tensor
boundary is available for larger kernels and future multi-instance batching
without imposing Nx on the core or slowing existing clients.
