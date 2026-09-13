# BeamicomPhx

Browser client for the [`beamicom_nes`](../beamicom_nes/README.md) NES and
[`beamicom_gbc`](../beamicom_gbc/README.md) Game Boy emulator cores. A Phoenix
LiveView app streams the active console's audio/video over WebRTC and relays
controller input back through the shared host/stream boundaries.

It is one of the projects in the combined
[Beamicom repository](../README.md):

```
beamicom/          # core emulator (headless)
beamicom_gbc/      # DMG/Game Boy Color core
beamicom_host/     # system-neutral A/V and input contracts
beamicom_stream/   # shared runtime and Membrane sources
beamicom_scenic/   # desktop client — Scenic/OpenGL window
beamicom_phx/      # this project — browser client
```

![Screenshot](./assets/screenshot.png)

## Modes

The app runs in one of two modes set by the `BEAMICOM_MODE` env var (default: `server`).

| Mode | What it does |
|------|-------------|
| `server` | Runs the emulator locally, encodes A/V with FFmpeg/Opus, and streams it to every connected browser over WebRTC. Accepts ROM drops and controller input from the browser. |
| `client` | Attaches to a running server node's A/V relay and sends browser controls to that server over a Phoenix Channel. No local emulator or ROM drop. |

## Setup

The local core and host path dependencies are already included in the repository:

```
beamicom/         # core dependency
beamicom_gbc/     # Game Boy core dependency
beamicom_host/    # neutral host contracts
beamicom_stream/  # shared Membrane A/V and RTP components
beamicom_phx/     # this project
```

From the repository root:

```sh
cd beamicom_phx
mix setup           # deps + assets
```

## Running

### Server mode

```sh
BEAMICOM_ROM=roms/game.gbc mix phx.server
```

`BEAMICOM_ROM` is required when starting the non-test application in server
mode and accepts a `.nes`, `.gb`, or `.gbc` ROM. You can swap among those
formats at runtime from the browser. Format-dependent stream changes remount
the browser player so WebRTC negotiates the active dimensions and channel
layout.

Default port: **4044**.

### Client mode

Start the server with an RTP target pointing at the client machine:

```sh
BEAMICOM_ROM=roms/game.nes \
BEAMICOM_IP=0.0.0.0 \
BEAMICOM_RTP_TARGET=CLIENT_IP:5000 \
mix phx.server
```

Then start the client with the browser-reachable URL of the server:

```sh
BEAMICOM_MODE=client \
BEAMICOM_IP=0.0.0.0 \
BEAMICOM_SERVER_URL=http://SERVER_IP:4044 \
mix phx.server
```

Default port: **4046**. Open `http://CLIENT_IP:4046`. A/V arrives over RTP on
UDP ports 5000 (AV1 video) and 5002 (Opus audio); controls go from the browser
to `ws://SERVER_IP:4044/controller/websocket` as a standard Phoenix Channel and
are forwarded through the server's system-aware input boundary. Allow those
ports through any host firewall. `BEAMICOM_RTP_LISTEN` changes the base UDP
port; audio always uses base + 2.

`BEAMICOM_IP=0.0.0.0` makes the development endpoint reachable from other
machines; omit it when both processes and the browser run on one host. Server
mode has no authentication for controller access or ROM uploads, and an upload
replaces the global emulator for every viewer. Treat it as a trusted-network
service; do not expose server mode publicly without authentication and
authorization.

The reusable RGB/PCM sources, AV1 packetizer, RTP timestamp/serialization code,
and AV1/Opus UDP broadcaster live in `beamicom_stream`. This project keeps the
Phoenix UI, browser controls, WebRTC signaling/sink, and client relay.

## Browser UI

- **Video** — CRT-styled WebRTC stream using 4:3 for NES and 10:9 for Game Boy,
  unmuted on first key/pointer press (browsers block autoplay audio).
- **Controller** — keyboard bindings, an on-screen touch gamepad, and physical
  USB/Bluetooth controllers through the browser Gamepad API. The first connected
  physical controller uses its standard D-pad/left stick, A/B, Select, and Start
  mapping. In client mode, input is relayed to the server selected by
  `BEAMICOM_SERVER_URL`. Player 1 remains local to the server; the first connected
  client becomes Player 2 for NES. Game Boy has one controller, so browser
  inputs are aggregated into Player 1 and a disconnected browser releases only
  its own held buttons. Additional clients still use the FIFO seat queue.

| Key | Console button |
|-----|------------|
| Arrow keys | D-pad |
| X | A |
| Z | B |
| Enter | Start |
| Shift | Select |

- **ROM drop zone** *(server mode only)* — drag a `.nes`, `.gb`, or `.gbc` file onto the labelled
  area at the bottom of the page to (re)load the emulator. All connected
  browsers pick up the new game immediately.

- **Save gallery** *(server mode only)* — NES and Game Boy/Game Boy Color saves
  are self-contained share PNGs. The gameplay screenshot is framed by a visible,
  lossless dot-code border containing the versioned emulator state; the immutable
  ROM is carried in an exact-transfer PNG trailer and verified before restore.
  Game Boy screenshots are nearest-neighbor enlarged from 160×144 to 640×576
  before the border is added. A save can switch the active emulator family when
  loaded. Client mode can view the gallery but cannot capture or restore saves.
