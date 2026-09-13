# Beamicom

Beamicom is a multi-system emulator workspace written in Elixir. It contains
separate headless NES and Game Boy/Game Boy Color cores, a small system-neutral
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
| [`beamicom_nes`](./beamicom_nes/) | Headless NES core: CPU, PPU, APU, mappers, input, and audio/video output | [Core documentation](./beamicom_nes/README.md) · [Mapper compatibility](./beamicom_nes/MAPPERS.md) |
| [`beamicom_nes_nx`](./beamicom_nes_nx/) | Optional EXLA renderers for batched NES video and audio work | [Nx renderer documentation](./beamicom_nes_nx/README.md) |
| [`beamicom_gbc`](./beamicom_gbc/) | Headless DMG/CGB core with an SM83 CPU, mapped devices, cartridge controllers, video, and audio | [Game Boy core documentation](./beamicom_gbc/README.md) |
| [`beamicom_scenic`](./beamicom_scenic/) | NES desktop client using Scenic/OpenGL, with optional audio through `ffplay` | [Desktop setup and controls](./beamicom_scenic/README.md) |
| [`beamicom_phx`](./beamicom_phx/) | NES/GB/GBC Phoenix LiveView client with browser WebRTC and controls | [Web setup and modes](./beamicom_phx/README.md) |
| [`beamicom_stream`](./beamicom_stream/) | Local NES/GB/GBC AV1/Opus RTP client with terminal controls and optional ffplay launch | [Local streaming setup](./beamicom_stream/README.md) |
| [`beamicom_v4l2`](./beamicom_v4l2/) | NES/GB/GBC Linux framebuffer/V4L2 client with controller mapping | [Build and usage](./beamicom_v4l2/README.md) |

Both cores depend on the sibling host contract. The stream, Phoenix, and V4L2
clients directly depend on both cores and the host; Scenic remains NES-only.
These are sibling path dependencies, so keep the directories together when
working with an individual project.

```text
beamicom_nes ─────> beamicom_host
beamicom_nes_nx ──> beamicom_nes
beamicom_gbc ─────> beamicom_host
beamicom_stream ──> beamicom_nes
beamicom_stream ──> beamicom_gbc
beamicom_stream ──> beamicom_host
beamicom_scenic ──> beamicom_nes
beamicom_v4l2 ────> beamicom_nes, beamicom_gbc, beamicom_host
beamicom_phx ─────> beamicom_nes
beamicom_phx ─────> beamicom_gbc
beamicom_phx ─────> beamicom_host
beamicom_phx ─────> beamicom_stream
```

## Quick start

Each project has its own Mix configuration and should be run from its directory.

Run either core or the shared host test suite:

```sh
cd beamicom_nes
mix test

cd ../beamicom_gbc
mix test

cd ../beamicom_host
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
