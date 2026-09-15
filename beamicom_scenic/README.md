# BeamicomScenic

Local-verification client for the NES, Game Boy / Game Boy Color, and SNES cores.
A [Scenic](https://hexdocs.pm/scenic) window renders each core's native video
output and a host-owned audio sink plays PCM. Keeping this host separate means
no emulator core takes a Scenic, OpenGL, or platform audio dependency.

![Screenshot](./assets/screenshot.jpg)

## Installation

The `scenic_driver_local` window uses native GLFW/GLEW + OpenGL, so those must be
installed before fetching dependencies.

### macOS

```sh
brew install glfw glew pkg-config sdl2
```

`scenic_driver_local`'s native build finds them via `pkg-config`. If compilation
can't locate GLFW/GLEW, point `PKG_CONFIG_PATH` at Homebrew's `.pc` files:

```sh
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/glew/lib/pkgconfig"
```

Normal-speed audio uses a bounded SDL2 device queue on macOS and Linux. ffplay
remains the fallback and provides pitch-preserving playback at other speeds:

```sh
brew install ffmpeg
```

### Linux (Debian/Ubuntu)

```sh
sudo apt install pkg-config libglfw3-dev libglew-dev libsdl2-dev zenity ffmpeg
```

The native ROM and save-state selectors use Zenity in an isolated process, so a
GTK dialog failure cannot crash or block the BEAM VM.

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
cd /path/to/beamicom/beamicom_scenic
export BEAMICOM_SCENIC_NX=1

mise exec -- mix deps.get
mise exec -- mix deps.compile beamicom_nes beamicom_gbc --force
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
#=> Beamicom.GB.Nx.APUSynthRenderer
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
starts PCM playback with the first audio chunk published after the first video
frame, without adding a platform-specific startup delay. Later machines in the
same BEAM instance reuse the compiled programs. Game Boy slices are paced from
their actual PCM duration, including longer intervals while a ROM disables the
LCD.

To return to the native renderer defaults, unset the flag and rebuild the same
dependencies:

```sh
unset BEAMICOM_SCENIC_NX
mise exec -- mix deps.compile beamicom_nes beamicom_gbc --force
mise exec -- mix compile --force
```

## Usage

```sh
iex -S mix
```

Open the long-lived Scenic shell without loading media:

```elixir
Beamicom.Scenic.start()
```

The same window remains open while emulator sessions are loaded and stopped.
The existing `play/2` calls start the shell automatically when needed:

```elixir
Beamicom.Scenic.play("../beamicom_nes/roms/game.nes")
Beamicom.Scenic.play("/path/to/game.nes", video_filter: :composite, scale: 1)
Beamicom.Scenic.play("/path/to/open-source-game.gbc")
Beamicom.Scenic.play("/path/to/game.gbc", video_filter: :pixel_transparency, scale: 3)
Beamicom.Scenic.play("/path/to/game.gb", scale: 4)   # integer scale, default 3
Beamicom.Scenic.play("/path/to/game.gbc", speed: 0.5) # half speed, default 1.0
Beamicom.Scenic.play("../beamicom_snes/roms/Super Mario World.sfc")
```

`.sfc` and `.smc` files can be loaded through a temporary Scenic adapter for
checking the progress of the in-development SNES core. Its current frame and
32 kHz stereo audio boundaries use the same host runtime, prebuffered audio
sink, and `GameSurface` as the other cores. Scenic selects the SNES Nx renderer
by default so the audio producer remains realtime; the standalone SNES package
retains its native-renderer default. Controller input and save states are
disabled until the core supports them. If an unimplemented CPU instruction is
reached, the adapter freezes at that point and continues displaying the current
PPU state for inspection.

### Persistent configuration

The in-window Config menu writes JSON to
`$XDG_CONFIG_HOME/beamicom/config.json`, falling back to
`~/.config/beamicom/config.json`. It stores:

- The initial folder for save-state open/save dialogs.
- The five most recently loaded ROM paths shown in the Game menu.
- The default NES filter: None, Composite, S-Video, or RGB.
- ROM-specific NES sprite lighting for verified light-source profiles.
- NES enhancements for removing the eight-sprites-per-scanline limit and trimming the horizontal borders.
- The default Game Boy/Game Boy Color filter: None or Pixel Transparency.
- Whether framebuffer presentation is constrained to whole-number scaling stages.
- Whether audio is enabled for newly loaded sessions.
- The Scenic playback volume, from 0% through 100%.

```json
{
  "version": 3,
  "save_state_folder": "/home/player/.local/share/beamicom/states",
  "recent_roms": [
    "/home/player/roms/Metroid.nes",
    "/home/player/roms/Tetris.gb"
  ],
  "nes_video_filter": "composite",
  "nes_lighting": false,
  "nes_remove_sprite_limit": false,
  "nes_trim_borders": false,
  "gbc_video_filter": "pixel_transparency",
  "integer_scaling": true,
  "audio": true,
  "volume": 100
}
```

Integer scaling applies immediately. It renders directly at the largest complete
stage that fits the current gameplay or paused-HUD area, then jumps to the next
stage only when enough room is available. For example, native NES progresses
through 256×240, 512×480, 768×720, and 1024×960 without intermediate sizes.
This keeps the final Scenic transform at 1× with pixel-aligned placement, so no
bilinear resampling is used. The local driver does not scale the viewport itself;
window resize events instead trigger a fresh layout at the real window size.
Turning integer scaling off restores flexible fractional fitting.

Filter and sprite-lighting changes apply immediately to a matching active system
while preserving the current emulation state and paused/running mode. Lighting
activates only when the loaded ROM has a verified profile. NES enhancement
changes also apply immediately to the active runtime and survive Reset and
video-filter changes. Volume changes apply immediately in Scenic and survive
Reset; enabling or disabling audio applies on the next load or reset. Explicit
options passed to `play/2` or `replace/2` take precedence over persisted defaults
at startup.
The save-state folder defaults to `$XDG_DATA_HOME/beamicom/states`, falling back
to `~/.local/share/beamicom/states`.

Enable the effect from **Config → NES → Sprite lighting**. The player status
field `lighting` is `true` when the requested setting matched and activated a ROM
profile, and `false` for unsupported ROMs or an explicitly native renderer.

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
selects either core too. The in-window Game menu can load media, reset or resume
the current session, and save or load the self-contained PNG states supported by
both cores. File selection uses a C NIF with an isolated AppKit helper on macOS
and an isolated Zenity process on Linux; it does not require Rust.

The multi-system scene, audio sink, and asset library live under
`Beamicom.Scenic`. Their former `Beamicom.NES` module names remain available as
compatibility wrappers, so existing entry points and custom viewport
configuration continue to work.

Only one local Scenic player runs at a time. A second `play/2` call is rejected
without starting more emulator or output processes. `replace/2` intentionally
swaps the session while preserving the shell and window. Inspect, pause, reset,
unload, or stop the owner explicitly when driving it from a long-lived IEx
session:

```elixir
Beamicom.Scenic.status()
Beamicom.Scenic.pause()
Beamicom.Scenic.resume()
Beamicom.Scenic.reset()
Beamicom.Scenic.unload()
Beamicom.Scenic.stop()
```

Closing the native window follows the owner-controlled shutdown path: it stops
active emulation, audio, input, streamed assets, Scenic, and its task supervisor
before requesting an orderly BEAM shutdown.

Without an NTSC filter, the viewport uses 256×240 as the NES 1× stage and
160×144 as the Game Boy 1× stage. CGB RGB24 is displayed directly; original
Game Boy shade indices use the core's green display palette. Resizing centers
the display and selects a new whole-number stage only after it fully fits. NES
audio is 44.1 kHz mono; Game Boy and SNES audio are stereo. All three systems
share Scenic's Config-menu volume slider.

### Controls (player 1)

| Key | Button |
|-----|--------|
| Arrow keys | D-pad |
| `X` | A |
| `Z` | B |
| Enter | Start |
| Right Shift | Select |
| `F5` | Quick-save state |
| `F8` | Quick-load state |

Gameplay displays only the framebuffer on a black field, with no menu, status
bar, or animated background. `Escape` pauses gameplay and opens the Game menu;
pressing `Escape` again resumes and restores the HUD-free game view. The arrow
keys and Enter navigate an open menu. During gameplay, `.` requests a
debug step and `g` toggles the NES raw palette-address grayscale view. `F5`
quick-saves and `F8` quick-loads while running or paused. The quick slot is
`<rom-sha256>.png` in the configured save-state folder; NES hashes its parsed
PRG+CHR data, while Game Boy hashes the cartridge ROM. Save and load state
actions appear in the Game menu only while a game is loaded. The Game menu also
lists the five most recently loaded ROMs by filename. Load State opens a horizontal,
ROM-specific preview browser; use Left/Right or the scroll wheel, Enter to load,
`O` or Open... for the native picker, and Escape to close it.
