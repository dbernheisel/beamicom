# Beamicom Stream

`beamicom_stream` is Beamicom's headless local client. It starts a ROM, encodes
the emulator's RGB video as AV1 and PCM audio as Opus, and sends both tracks over
RTP to a local player. It does not require Phoenix, a browser, a framebuffer, or
V4L2.

## Setup

Use the repository's mise-managed Erlang and Elixir toolchains:

```sh
mise install
cd beamicom_stream
mise exec -- mix deps.get
```

The Membrane AV1 and Opus plugins use precompiled native codec libraries on
supported systems. `ffplay` is required for the default player. No ROM is
included; supply a legally obtained `.nes` file.

## Play a ROM

```sh
cd beamicom_stream
mise exec -- mix beamicom.stream /absolute/path/to/game.nes
```

The command creates a temporary SDP file, starts ffplay as the receiver, then
starts the Membrane pipeline and emulator. The SDP makes the two RTP tracks one
logical playback session:

- AV1 video uses UDP port 5000 and RTP payload type 96.
- Opus mono audio uses UDP port 5002 and RTP payload type 111.

The temporary SDP and child processes are cleaned up when play ends.

### Controls

| Key | NES control |
| --- | --- |
| Arrow keys | D-pad |
| X | A |
| Z | B |
| Enter | Start |
| Space | Select |
| Q or Escape | Quit |

Portable terminals do not expose key-release events or a standalone Shift key.
The input reader therefore releases each button 120 ms after its last key press;
normal keyboard repeat keeps a held direction active. Space represents Select.
For exact press/release semantics, call the Player API or add an evdev adapter.
The terminal is restored from raw/no-echo mode on normal task cleanup.

## Options

```sh
mix beamicom.stream game.nes \
  --host 127.0.0.1 \
  --port 5000 \
  --controller 1
```

`--port` is the video port; audio uses that port plus two. Choose a base port no
higher than 65533. `--ffplay /path/to/ffplay` selects another executable.

For a headless session, skip launching ffplay:

```sh
mix beamicom.stream game.nes --no-player
```

The task still reads `/dev/tty`. For programmatic/headless control, start the
Player directly and provide buttons through its API:

```elixir
{:ok, player} =
  BeamicomStream.play("game.nes", target: {{127, 0, 0, 1}, 5000})

BeamicomStream.set_buttons(player, [:right, :a])
BeamicomStream.set_buttons(player, [])
BeamicomStream.stop(player)
```

To open an SDP manually, ffplay needs access to its file, UDP, and RTP protocols:

```sh
ffplay -protocol_whitelist file,udp,rtp stream.sdp
```

AV1-over-RTP demuxing depends on the ffplay/FFmpeg build. If it rejects the AV1
RTP mapping, use a current FFmpeg build with AV1 RTP support; the emulator and
Membrane stream can still run with `--no-player`.

## Tests

Hardware-independent tests do not open a terminal, audio device, or UDP player:

```sh
mise exec -- mix test
```

The native codec smoke test and a checked-in-ROM FFmpeg decode test are excluded
by default:

```sh
mise exec -- mix test --include integration
mise exec -- mix test --include ffmpeg_e2e
```
