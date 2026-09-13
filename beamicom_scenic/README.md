# BeamicomScenic

Local-verification client for the [`beamicom_nes`](../beamicom_nes/README.md) NES and
Game Boy / Game Boy Color cores. A [Scenic](https://hexdocs.pm/scenic) window
renders each core's native video output and an optional ffmpeg player process
handles audio. Keeping this host separate means neither emulator core takes a
Scenic or OpenGL dependency.

![Screenshot](./assets/screenshot.jpg)

## Installation

The `scenic_driver_local` window uses native GLFW/GLEW + OpenGL, so those must be
installed before fetching dependencies.

### macOS

```sh
brew install glfw glew pkg-config
```

`scenic_driver_local`'s native build finds them via `pkg-config`. If compilation
can't locate GLFW/GLEW, point `PKG_CONFIG_PATH` at Homebrew's `.pc` files:

```sh
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/glew/lib/pkgconfig"
```

Audio playback shells out to ffmpeg's low-latency `audiotoolbox` output on
macOS; it's optional — the sink declines gracefully if ffmpeg is missing:

```sh
brew install ffmpeg
```

### Linux (Debian/Ubuntu)

```sh
sudo apt install pkg-config libglfw3-dev libglew-dev ffmpeg
```

### Fetch and compile

This project and its core path dependencies are included in the same repository:

```
beamicom/          # core emulator
beamicom_gbc/      # Game Boy / Game Boy Color core
beamicom_host/     # shared host contracts
beamicom_scenic/   # this project
```

From the repository root:

```sh
cd beamicom_scenic
mix deps.get
mix compile
```

## Compile-time Nx acceleration

The NES PPU and APU renderer choices are compile-time settings. Scenic provides
one opt-in flag that selects both `Beamicom.NES.Nx.PPURenderer` and
`Beamicom.NES.Nx.APUBlockRenderer`. The PPU renderer is atlas-first and
automatically uses its internal byte/hybrid fallback where a cartridge requires
it.

Keep the flag exported while compiling and running. When changing it for an
existing build, force-recompile the affected path dependencies:

```sh
cd /home/dbern/beamicom/beamicom_scenic
export BEAMICOM_SCENIC_NX=1

mise exec -- mix deps.get
mise exec -- mix deps.compile beamicom_nes beamicom_nes_nx beamicom_gbc beamicom_gbc_nx --force
mise exec -- mix compile --force
mise exec -- iex -S mix
```

Confirm both compiled selections from IEx:

```elixir
Beamicom.NES.PPU.configured_renderer()
#=> Beamicom.NES.Nx.PPURenderer

Beamicom.NES.Bus.configured_apu_renderer()
#=> Beamicom.NES.Nx.APUBlockRenderer

Beamicom.GB.PPU.configured_renderer()
#=> Beamicom.GB.Nx.PPURenderer

Beamicom.GB.APU.configured_renderer()
#=> Beamicom.GB.Nx.APUBlockRenderer
```

Normal atlas-first Nx video with the Nx block APU then needs no per-game renderer
option:

```elixir
Beamicom.Scenic.play("/path/to/game.nes", scale: 3)
```

The Blargg filter replaces only the PPU presentation renderer for that console;
the compile-time Nx APU remains selected:

```elixir
Beamicom.Scenic.play("/path/to/game.nes", video_filter: :composite, scale: 1)
```

The Nx APU graph for either core is compiled while the machine starts. Scenic
holds the initial PCM until the first video frame, so first-use PPU compilation
cannot start and then starve the audio player. Later machines in the same BEAM
instance reuse the compiled programs. Game Boy slices are paced from their
actual PCM duration, including longer intervals while a ROM disables the LCD.

To return to the dependency-free renderer defaults, unset the flag and rebuild
the same dependencies:

```sh
unset BEAMICOM_SCENIC_NX
mise exec -- mix deps.compile beamicom_nes beamicom_nes_nx beamicom_gbc beamicom_gbc_nx --force
mise exec -- mix compile --force
```

## Usage

```sh
iex -S mix
```
```elixir
Beamicom.Scenic.play("../beamicom_nes/roms/game.nes")
Beamicom.Scenic.play("/path/to/game.nes", video_filter: :composite, scale: 1)
Beamicom.Scenic.play("/path/to/open-source-game.gbc")
Beamicom.Scenic.play("/path/to/game.gbc", video_filter: :pixel_transparency, scale: 3)
Beamicom.Scenic.play("/path/to/game.gb", scale: 4)   # integer scale, default 3
Beamicom.Scenic.play("/path/to/game.gbc", speed: 0.5) # half speed, default 1.0
```

For the Nx Blargg NTSC filter, `:video_filter` accepts `:composite`, `:svideo`,
`:rgb`, or `:monochrome`; `:native` explicitly disables it. The filtered image
is 602×240 and Scenic automatically doubles its scanlines for the intended
square-pixel presentation. Blargg modes therefore default to `scale: 1`, opening
a 602×480 game surface; an explicit scale still overrides it. The same selection
can be supplied through `BEAMICOM_NES_VIDEO_FILTER`:

```sh
BEAMICOM_NES_VIDEO_FILTER=composite mise exec -- iex -S mix
```

For Game Boy and Game Boy Color, `video_filter: :pixel_transparency` runs the Nx
LCD and transparency passes after DMG palette conversion or CGB RGB composition.
It adds subpixel/scanline modulation, a textured reflective backing behind
bright pixels, polarizer tint, and offset LCD shadows. Set
`BEAMICOM_GBC_VIDEO_FILTER=pixel_transparency` to select it without passing the
option on every launch. Parameters can be overridden with
`video_filter_options`; for example:

```elixir
Beamicom.Scenic.play("/path/to/game.gbc",
  scale: 3,
  video_filter: :pixel_transparency,
  video_filter_options: [base_alpha: 0.3, shadow_opacity: 0.6]
)
```

The local driver is configured with `limit_ms: 0`. Its upstream 29 ms default
would otherwise cap streamed framebuffer updates at roughly 34 FPS; Beamicom's
output hub and the driver's busy state already coalesce superseded frames.

Then start the ROM without repeating the option:

```elixir
Beamicom.Scenic.play("/path/to/game.nes", scale: 1)
```

Or launch it directly, without an interactive IEx prompt:

```sh
mise exec -- mix run --no-halt -e 'Beamicom.Scenic.play("/path/to/game.nes", video_filter: :composite, scale: 1)'
```

Any positive speed is accepted. Values below 1 slow emulation and values above
1 accelerate it; the audio sink chains pitch-preserving `atempo` filters to
match the selected rate.

The existing `Beamicom.NES.Scenic.play/2` entry point remains available and now
selects either core too. NES save PNGs are supported as before. Game Boy save
states are not yet implemented.

The multi-system scene, audio sink, and asset library live under
`Beamicom.Scenic`. Their former `Beamicom.NES` module names remain available as
compatibility wrappers, so existing entry points and custom viewport
configuration continue to work.

Only one local Scenic player runs at a time. A second `play/2` call is rejected
without starting more emulator or output processes. Inspect or stop the owner
explicitly when driving it from a long-lived IEx session:

```elixir
Beamicom.Scenic.status()
Beamicom.Scenic.stop()
```

Without an NTSC filter, the viewport uses the core's native dimensions before
integer scaling: 256×240 for NES and 160×144 for Game Boy. CGB RGB24 is displayed directly; original Game
Boy shade indices use the core's green display palette. Resizing the window
scales and centers the display while preserving its aspect ratio. NES audio is
44.1 kHz mono and Game Boy audio is 44.1 kHz stereo.

### Controls (player 1)

| Key | Button |
|-----|--------|
| Arrow keys | D-pad |
| `X` | A |
| `Z` | B |
| Enter | Start |
| Right Shift | Select |

Debug keys: `Space` pause/resume, `.` step one frame while paused, `g` toggle the
raw palette-address grayscale view. The grayscale toggle and the in-window Save
button are NES-only; pause and step work with either core.
