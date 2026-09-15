# Optional GBC Nx renderers

Optional Nx frame and audio renderer modules in `beamicom_gbc`, covering both
DMG and CGB execution. The dependency-free core keeps LCD timing and memory access
rules in Elixir. The renderer receives frame-start VRAM, OAM, and palette RAM,
nine control bytes per scanline, and accepted visible memory writes tagged with
the first line they affect. At VBlank one compiled Nx operation performs tile-map
and pattern lookup, selects the first 10 eligible sprites from the 40 OAM entries
on each line, rasterizes only their 8-pixel spans, expands bit planes, and
composes all 144×160 pixels.

The sole Nx audio implementation, `Beamicom.GB.Nx.APUSynthRenderer`, accepts
compact control epochs and keeps pulse timers, wave position, noise LFSR, and
sample phase on the configured Nx backend across frames. Its device state,
exact-rate sample clock, channel evaluation, routing, and mixer are integer-only.
A short sequential pass resolves the state at each timestamped control epoch,
then one frame-wide tensor operation synthesizes every output sample in
parallel. The model-specific analog high-pass recurrence remains on the host
because each output depends on the preceding capacitor value.

Add Nx and EXLA to the client and select the core renderers in compile-time
configuration:

```elixir
{:beamicom_gbc, path: "../beamicom_gbc"}
{:nx, "~> 1.0"}
{:exla, "~> 1.0"}

config :beamicom_gbc,
  ppu_renderer: Beamicom.GB.Nx.PPURenderer,
  apu_renderer: Beamicom.GB.Nx.APUSynthRenderer

config :nx, :default_defn_options, compiler: EXLA, client: :host
```

For the standalone project configuration, select both Nx renderers with:

```sh
BEAMICOM_NX=1 mix compile
```

Changing a renderer requires recompiling `beamicom_gbc`. The Nx compiler is
selected when each graph is prepared, and the compiled cache is partitioned by
compiler options so frame replay does not query configuration.

PPU and APU graphs are compiled and cached on first use. PPU event capacities
and steady-state versus boot-sized APU outputs have separate cached shapes.

Nx and its compiler remain optional dependencies of the core. PPU and APU
programs resolve sequentially at the host output boundary, and backend-resident
audio state is copied through the renderer's snapshot/restore callbacks for
portable save states.

Compare implementations with the deterministic benchmark task:

```sh
mix gb.bench /path/to/game.gbc --frames 120 --repeats 3 \
  --renderer nx --audio-renderer nx
```

Pass `--state /path/to/gameplay.png` to replay a share-image save instead of
profiling only cold boot. The task verifies that the state's cartridge matches
the ROM and reports both hashes plus the saved starting frame.

The dependency-free core uses its Elixir block mixer by default, while an Nx
build selects event-driven integer synthesis at compile time. Pixel and PCM
hashes match the native implementations. The shared bus avoids full timer/PPU
dispatch when a timer-off CPU cycle remains within the current LCD mode and
uses direct cycle reads for ROM, WRAM, and HRAM; exact processing remains at
every LCD boundary.

The base frame payload is about 18 KB: 16 KB VRAM, 160-byte OAM, 128-byte CGB
palette RAM, and 1,296 bytes of scanline controls. Each visible memory write adds
one compact event. Static frames retain the one-dimensional memories. Frames
with visible writes reconstruct the memory visible to all 144 scanlines once,
in parallel, and subsequent tile, sprite, and palette reads gather from those
rows. The graph is identical on EXLA host and ROCm. Runtime renderer detection
is compiled out of normal PPU and APU builds; it is enabled only by the Nx
cross-backend test configuration.

In a separate five-run, 300-frame comparison of the full event-block
synthesizer, changing from per-epoch sample batches to one frame-wide sample
batch raised the median from 69.13 to 73.19 FPS on the EXLA host client and
from 58.65 to 60.81 FPS on ROCm. Audio and video hashes were unchanged. The
end-to-end gain is modest because the PPU dominates this workload; it should
not be read as an isolated APU-kernel speedup.

Sparse sprite rasterization then reduced the sprite candidate tensor from
144×40×160 pixels to 144×10×8 pixels. In the same five-run, 300-frame workload,
the ROCm median rose from 60.81 to 65.37 FPS (7.5%), while the EXLA host median
fell from 73.19 to 70.18 FPS (4.1%). Audio and video output remained identical.

A separate timed-write microbenchmark compared reconstructing per-scanline
memory with replaying every event at every read site. On ROCm, reconstruction
was faster for 1, 2, 4, 8, and 16 writes, ranging from 1.39× to 3.16× faster as
the event count increased. It was about 1.7–1.9× slower on the EXLA host in
that isolated benchmark. The common implementation favors one portable Nx
graph over backend-specific behavior. Static frames bypass event reconstruction.

`Beamicom.GB.Nx.PixelTransparency` ports Matt Akins'
[Pixel Transparency](https://github.com/mattakins/Pixel_Transparency) shader.
It treats bright pixels as translucent LCD cells over a textured backing and adds
subpixel modulation, polarizer tint, and static blurred shadows. Scenic exposes it
as `video_filter: :pixel_transparency`; direct callers can use
`PixelTransparency.filter/4` or the resident-tensor `filter_tensor/3`.
