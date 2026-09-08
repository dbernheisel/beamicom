# BeamicomScenic

Local-verification client for the [`beamicom`](../beamicom/README.md) NES and
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

## Usage

```sh
iex -S mix
```
```elixir
Beamicom.Scenic.play("../beamicom/roms/game.nes")
Beamicom.Scenic.play("/path/to/open-source-game.gbc")
Beamicom.Scenic.play("/path/to/game.gb", scale: 4)   # integer scale, default 3
Beamicom.Scenic.play("/path/to/game.gbc", speed: 0.5) # half speed, default 1.0
```

Any positive speed is accepted. Values below 1 slow emulation and values above
1 accelerate it; the audio sink chains pitch-preserving `atempo` filters to
match the selected rate.

The existing `Beamicom.NES.Scenic.play/2` entry point remains available and now
selects either core too. NES save PNGs are supported as before. Game Boy save
states are not yet implemented.

Only one local Scenic player runs at a time. A second `play/2` call is rejected
without starting more emulator or output processes. Inspect or stop the owner
explicitly when driving it from a long-lived IEx session:

```elixir
Beamicom.Scenic.status()
Beamicom.Scenic.stop()
```

The viewport uses the core's native dimensions before integer scaling: 256×240
for NES and 160×144 for Game Boy. CGB RGB24 is displayed directly; original Game
Boy shade indices use the core's green display palette. NES audio is 44.1 kHz
mono and Game Boy audio is 44.1 kHz stereo.

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
