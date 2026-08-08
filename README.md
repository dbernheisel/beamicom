# Beamicom

Beamicom is a cycle-aware NES emulator written in Elixir. This repository keeps
the headless emulation core and two interactive clients together: a native
Scenic application and a Phoenix application that streams the console to a web
browser.

## In action

| Desktop client | Web client |
| --- | --- |
| [![Beamicom running in the Scenic desktop client](./beamicom_scenic/assets/screenshot.jpg)](./beamicom_scenic/README.md) | [![Beamicom running in the Phoenix browser client](./beamicom_phx/assets/screenshot.png)](./beamicom_phx/README.md) |

## Projects

| Project | Purpose | Start here |
| --- | --- | --- |
| [`beamicom`](./beamicom/) | Dependency-free emulator core: CPU, PPU, APU, 16 mapper numbers, input, and audio/video output | [Core documentation](./beamicom/README.md) · [Mapper compatibility](./beamicom/MAPPERS.md) |
| [`beamicom_scenic`](./beamicom_scenic/) | Desktop client using Scenic/OpenGL, with optional audio through `ffplay` | [Desktop setup and controls](./beamicom_scenic/README.md) |
| [`beamicom_phx`](./beamicom_phx/) | Phoenix LiveView client that streams audio/video over WebRTC and accepts browser controls | [Web setup and modes](./beamicom_phx/README.md) |
| [`beamicom_v4l2`](./beamicom_v4l2/) | Linux framebuffer/V4L2 client that boots ROMs and maps NES controls | [Build and usage](./beamicom_v4l2/README.md) |

Both clients use the core through the local path dependency
`../beamicom`, so keep these directories together when working with an
individual project.

```text
beamicom_scenic ─┐
beamicom_phx ────┼──> beamicom
beamicom_v4l2 ───┘
```

## Quick start

Each project has its own Mix configuration and should be run from its directory.

Run the core test suite:

```sh
cd beamicom
mix test
```

Launch the desktop client after installing its native prerequisites:

```sh
cd beamicom_scenic
mix deps.get
iex -S mix
```

Set up and launch the web client:

```sh
cd beamicom_phx
mix setup
BEAMICOM_ROM=/path/to/game.nes mix phx.server
```

See each project's README for prerequisites, usage, and controls. ROMs are not
required to build the projects; provide your own legally obtained ROM when
running the emulator.
