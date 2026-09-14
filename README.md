# Beamicom

Beamicom is a multi-system emulator workspace written in Elixir. It contains
separate headless NES and Game Boy/Game Boy Color cores, an early native SNES
core, a small system-neutral
host contract, NES desktop/Linux clients, and browser/local AV1/Opus clients
that can run NES, Game Boy, and Game Boy Color ROMs.

## In action

| Desktop client | Web client |
| --- | --- |
| [![Beamicom running in the Scenic desktop client](./beamicom_scenic/assets/screenshot.jpg)](./beamicom_scenic/README.md) | [![Beamicom running in the Phoenix browser client](./beamicom_phx/assets/screenshot.png)](./beamicom_phx/README.md) |

## Projects

| Project | Purpose | Start here |
| --- | --- | --- |
| [`beamicom_host`](./beamicom_host/) | Shared system, input, video/audio envelope, and coalesced-output contracts | [Host documentation](./beamicom_host/README.md) |
| [`beamicom_ei`](./beamicom_ei/) | Shared pure-Elixir EI Unix-socket controller server and client | [EI documentation](./beamicom_ei/README.md) |
| [`beamicom_nes`](./beamicom_nes/) | Headless NES core with native renderers and optional Nx/EXLA video and audio renderers | [Core documentation](./beamicom_nes/README.md) · [Mapper compatibility](./beamicom_nes/MAPPERS.md) |
| [`beamicom_gbc`](./beamicom_gbc/) | Headless DMG/CGB core with native renderers and optional Nx/EXLA frame and audio renderers | [Game Boy core documentation](./beamicom_gbc/README.md) |
| [`beamicom_snes`](./beamicom_snes/) | Early pure-Elixir SNES core: cartridge mapping, Mode 0/1 PPU, interrupts, audio timing, and a 65C816 interpreter seed | [SNES core status](./beamicom_snes/README.md) |
| [`beamicom_scenic`](./beamicom_scenic/) | Desktop client using Scenic/OpenGL, with optional audio through `ffplay` | [Desktop setup and controls](./beamicom_scenic/README.md) |
| [`beamicom_phx`](./beamicom_phx/) | Phoenix LiveView client with browser WebRTC and controls | [Web setup and modes](./beamicom_phx/README.md) |
| [`beamicom_stream`](./beamicom_stream/) | Local AV1/Opus RTP client with terminal controls and optional ffplay launch | [Local streaming setup](./beamicom_stream/README.md) |
| [`beamicom_v4l2`](./beamicom_v4l2/) | Linux framebuffer/V4L2 client with controller mapping | [Build and usage](./beamicom_v4l2/README.md) |

Both cores depend on the sibling host contract and shared EI controller
protocol. The client projects that use EI also declare it directly.
These are sibling path dependencies, so keep the directories together when
working with an individual project.

```text
beamicom_nes ─────> beamicom_host, beamicom_ei; optionally Nx and EXLA
beamicom_gbc ─────> beamicom_host, beamicom_ei; optionally Nx and EXLA
beamicom_snes       native foundation; host integration follows PPU/APU output
beamicom_stream ──> beamicom_nes, beamicom_gbc, beamicom_host, beamicom_ei
beamicom_scenic ──> beamicom_nes, beamicom_gbc, beamicom_host, beamicom_ei
beamicom_v4l2 ────> beamicom_nes, beamicom_gbc, beamicom_host, beamicom_ei
beamicom_phx ─────> beamicom_nes, beamicom_gbc, beamicom_host, beamicom_ei,
                    beamicom_stream
```

## Quick start

Each project has its own Mix configuration and should be run from its directory.

Run either core or one of the shared-library test suites:

```sh
cd beamicom_nes
mix test

cd ../beamicom_gbc
mix test

cd ../beamicom_host
mix test

cd ../beamicom_snes
mix test

cd ../beamicom_ei
mix test
```

Launch the desktop client after installing its native prerequisites:

```sh
cd beamicom_scenic
mix deps.get
iex -S mix
```

Run a NES, Game Boy, or Game Boy Color ROM through the local RTP player:

```sh
cd beamicom_stream
mix deps.get
mix beamicom.stream /path/to/game.nes
mix beamicom.stream /path/to/game.gb
mix beamicom.stream /path/to/game.gbc
```

Use `--no-player` to send the stream without launching ffplay. See the stream
README for RTP ports, prerequisites, terminal controls, and the programmatic
Player API.

Set up and launch the web client:

```sh
cd beamicom_phx
mix setup
BEAMICOM_ROM=/path/to/game.nes mix phx.server
```

`BEAMICOM_ROM` accepts `.nes`, `.gb`, and `.gbc` files. The server-mode browser
also accepts those formats through its ROM drop zone.

GB/GBC streaming exposes the current core; it is not a claim of full software
compatibility. The core currently implements ROM-only cartridges plus MBC1,
MBC2, MBC3, and MBC5, with known PPU/APU timing limitations documented in its
README.

See each project's README for prerequisites, usage, and controls. ROMs are not
required to build the projects; provide your own legally obtained ROM when
running the emulator.
