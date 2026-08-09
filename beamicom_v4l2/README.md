# BeamicomV4L2

`BeamicomV4L2` is a Beamicom client backed by a Rustler NIF. It boots a ROM,
renders live emulator frames to the Linux framebuffer, continuously copies that
display to a V4L2 video-output device, and plays emulator audio through
`ffplay`. Common 16-, 24-, and 32-bit true-color framebuffer layouts are
converted to packed YUYV.

The NIF owns a background Rust thread, so frame conversion, pacing, and device
I/O do not block a BEAM scheduler. Dropping or stopping the Elixir process
signals that thread to close its framebuffer mapping and V4L2 descriptor.

## Play a ROM

Complete the [Linux device setup](#linux-device-setup) once, then install the
project toolchains and dependencies:

```sh
mise install
cd beamicom_v4l2
BEAMICOM_V4L2_BUILD=true mix deps.get
```

Start the player and its Unix-domain controller socket:

```sh
BEAMICOM_V4L2_BUILD=true mix beamicom.v4l2 /absolute/path/to/game.nes
```

The command stays in the foreground and prints the socket path. By default it
is `$XDG_RUNTIME_DIR/beamicom-ei.sock`, or `/tmp/beamicom-ei.sock`
when `XDG_RUNTIME_DIR` is unavailable. Stop the player with Ctrl-C.

To start the player programmatically instead, open an interactive Elixir
session:

```sh
BEAMICOM_V4L2_BUILD=true iex -S mix
```

At the IEx prompt, boot a legally obtained ROM:

```elixir
{:ok, player} = BeamicomV4L2.play("path/to/game.nes")
```

Audio begins automatically through the host's default SDL audio device. It is
fed directly from the emulator as signed 16-bit, 44.1 kHz mono PCM; the video
preview command below does not need to play or capture audio itself.

The game now runs at 60 fps and uses Scenic-style nearest-neighbor 3× scaling.
Its 768×720 video is drawn in the top-left of `/dev/fb0` and that game region is
published as `/dev/video-beamicom`. View it from another terminal:

```sh
ffplay -f v4l2 /dev/video-beamicom
```

Check that emulation and streaming are advancing:

```elixir
BeamicomV4L2.status(player)
```

Send controller events from IEx or another Elixir process:

```elixir
BeamicomV4L2.key_down("ArrowRight")
BeamicomV4L2.key_down("x")
BeamicomV4L2.key_up("x")
BeamicomV4L2.key_up("ArrowRight")
```

These functions map key events; the application does not read terminal
keystrokes directly. A UI, input-device process, or remote-control process
should call `key_down/2` and `key_up/2` when keys change state.

Stop the player with:

```elixir
BeamicomV4L2.stop(player)
```

For an unattended process, launch the same player without IEx:

```sh
BEAMICOM_V4L2_BUILD=true BEAMICOM_ROM=/absolute/path/to/game.nes \
  mix run --no-halt -e \
  'BeamicomV4L2.play(System.fetch_env!("BEAMICOM_ROM"))'
```

## Development

Mise installs the pinned Rust toolchain from the repository root:

```sh
mise install
cd beamicom_v4l2
BEAMICOM_V4L2_BUILD=true mix deps.get
BEAMICOM_V4L2_BUILD=true mix test
mix test.rust
```

`mix test.rust` uses mise to run `cargo fmt --check`, Clippy with warnings
denied, and the Rust unit tests—the same checks that gate precompiled releases.

`BEAMICOM_V4L2_BUILD=true` tells `rustler_precompiled` to compile the local crate.
Package consumers do not set it; they download a checksum-verified NIF from the
matching GitHub release instead.

## Supervision and API

Add a ROM player to a supervision tree:

```elixir
children = [
  {BeamicomV4L2,
   rom: "/absolute/path/to/game.nes",
   framebuffer: "/dev/fb0",
   output: "/dev/video-beamicom",
   fps: 60,
   scale: 3,
   name: BeamicomV4L2.Player}
]
```

Or launch it directly from IEx:

```elixir
{:ok, player} = BeamicomV4L2.play("/absolute/path/to/game.nes")

BeamicomV4L2.status(player)
#=> %{
#=>   rom: "/absolute/path/to/game.nes",
#=>   frame: 120,
#=>   scale: 3,
#=>   audio: %{
#=>     enabled: true, running: true, error: nil, chunks: 240, samples: 88200
#=>   },
#=>   controls: %{1 => [], 2 => []},
#=>   stream: %{running: true, frames: 119, error: nil}
#=> }

BeamicomV4L2.stop(player)
```

The ROM is required. The defaults are `/dev/fb0`, `/dev/video-beamicom`, 60
fps, 3× nearest-neighbor scaling, and audio enabled. Set `scale: 1` through
`scale: 8` when starting the player to select another integer scale.

### Audio

The player subscribes to the emulator's audio output and owns a separate
`ffplay` process for the lifetime of the ROM. Audio is best-effort: if `ffplay`
is unavailable or its audio device fails, `status/1` reports the error while
emulation and V4L2 video continue running.

Disable audio for CI, headless hosts, or capture-only use:

```elixir
{:ok, player} = BeamicomV4L2.play("path/to/game.nes", audio: false)
```

The runtime publishes audio twice per video frame by default to keep playback
latency down. `audio_slices: 1` uses one chunk per frame; higher values trade
more emulator scheduling overhead for smaller chunks. Slow-motion playback can
use `speed`, and the audio sink applies matching pitch-preserving tempo:

```elixir
BeamicomV4L2.play("path/to/game.nes", speed: 0.5, audio_slices: 2)
```

Advanced callers can replace the player command, for example when routing PCM
to a system-specific virtual sink:

```elixir
audio_command = [
  "ffmpeg", "-loglevel", "error",
  "-f", "s16le", "-ar", "44100", "-ac", "1", "-i", "pipe:0",
  "-f", "pulse", "beamicom"
]

BeamicomV4L2.play("path/to/game.nes", audio_command: audio_command)
```

The command receives raw signed 16-bit little-endian, 44.1 kHz mono PCM on
standard input.

V4L2 devices carry video only, so `/dev/video-beamicom` cannot contain an audio
track. To produce one A/V recording or network stream, route Beamicom audio to
a PipeWire/PulseAudio or ALSA virtual sink, then give both the V4L2 device and
that sink's monitor source to a muxer. For example, create a PulseAudio null sink
(also supported by PipeWire's PulseAudio compatibility layer):

```sh
pactl load-module module-null-sink sink_name=beamicom
```

Start the player with the `audio_command` above, then mux its monitor source with
the video:

```sh
ffmpeg \
  -f v4l2 -framerate 60 -i /dev/video-beamicom \
  -f pulse -i beamicom.monitor \
  -c:v libx264 -c:a aac beamicom.mkv
```

Configure `audio_command` to send raw PCM to that sink instead of the default
`ffplay`. This keeps the virtual camera usable by ordinary V4L2 clients while
the container or streaming protocol provides the combined A/V output.

### Controls

#### Unix socket control

`mix beamicom.v4l2` starts a pure-Elixir EI protocol server on a mode-`0600`
Unix-domain socket. Its terminal controller, Phoenix, and Scenic all use the
shared `Beamicom.EI.Client`. The wire format is the standard binary EI protocol.

The server advertises two devices with the `ei_button` capability. Changes
commit on `ei_device.frame`; disconnecting releases that client's held buttons.

For local keyboard control on Linux, the launcher auto-detects a readable evdev
keyboard so presses and releases—and multiple held buttons—are tracked
independently. Select a specific keyboard when needed with
`--input /dev/input/by-id/...-event-kbd`. If no readable event device exists,
the launcher falls back to terminal key-repeat input and prints a warning; that
fallback cannot reliably distinguish overlapping held keys because terminals do
not report key releases.

```elixir
{:ok, client} = Beamicom.EI.Client.start_link(path: Beamicom.EI.default_path())
:ok = Beamicom.EI.Client.await_ready(client)
:ok = Beamicom.EI.Client.set_buttons(client, 1, [:right, :a])
```

Select another path when launching if needed:

```sh
mix beamicom.v4l2 game.nes --socket /tmp/my-controller.sock
```

The reusable EI server, client, and codec live in core Beamicom without a NIF.

#### Direct API

The player tracks held buttons independently for controller ports 1 and 2.
Browser-style key names and Scenic-style key atoms use this default mapping:

| Input | NES button |
| --- | --- |
| Arrow keys / `:key_up`, `:key_down`, `:key_left`, `:key_right` | D-pad |
| `X` / `:key_x` | A |
| `Z` / `:key_z` | B |
| Enter / `:key_enter` | Start |
| Shift / `:key_leftshift`, `:key_rightshift` | Select |

Send key events:

```elixir
BeamicomV4L2.key_down("ArrowRight")
BeamicomV4L2.key_down("x")
BeamicomV4L2.key_up("x")
BeamicomV4L2.key_up("ArrowRight")
```

Or use NES button names directly, including controller 2:

```elixir
BeamicomV4L2.press(:start)
BeamicomV4L2.release(:start)
BeamicomV4L2.set_buttons([:left, :a], 2)
```

Pass `controls: %{custom_key => :a}` when starting the player to extend or
override the default map. Valid NES buttons are `:up`, `:down`, `:left`,
`:right`, `:a`, `:b`, `:start`, and `:select`.

`BeamicomV4L2.Stream.start_link/1` remains available as a lower-level API when
another program already renders into `/dev/fb0` and only mirroring is needed.

## Linux device setup

The destination must expose single-plane `V4L2_CAP_VIDEO_OUTPUT` and
`V4L2_CAP_READWRITE`, and accept YUYV at the configured game-region resolution
(768×720 by default).
Physical webcams are generally capture-only, so the E2E setup uses a
`v4l2loopback` virtual device.

### 1. Install the device support

On Ubuntu or Debian:

```sh
sudo apt install v4l2loopback-dkms v4l-utils ffmpeg
```

If Secure Boot is enabled, the machine may require enrollment of the DKMS
module signing key before `modprobe` can load the module.

### 2. Create the Beamicom loopback device

The kernel still requires a numbered V4L2 node. This command reserves
`/dev/video2`, labels it `Beamicom Framebuffer`, and configures it to switch
from output capability to capture capability while the NIF is producing:

```sh
sudo modprobe v4l2loopback \
  devices=1 \
  video_nr=2 \
  card_label="Beamicom Framebuffer" \
  exclusive_caps=1
```

The number `2` is not significant. Choose another unused number if
`/dev/video2` already belongs to a camera.

### 3. Give it a stable Beamicom name

Create `/etc/udev/rules.d/99-beamicom-video.rules` with this content:

```udev
SUBSYSTEM=="video4linux", ATTR{name}=="Beamicom Framebuffer", SYMLINK+="video-beamicom", GROUP="video", MODE="0660"
```

Then reload the rule and recreate the device:

```sh
sudo udevadm control --reload-rules
sudo modprobe -r v4l2loopback
sudo modprobe v4l2loopback \
  devices=1 \
  video_nr=2 \
  card_label="Beamicom Framebuffer" \
  exclusive_caps=1
```

The resulting `/dev/video-beamicom` symlink is independent of the chosen
`video_nr`. Confirm the devices and permissions:

```sh
test -c /dev/fb0
test -c /dev/video-beamicom
readlink -f /dev/video-beamicom
v4l2-ctl --device /dev/video-beamicom --all
```

Both device nodes normally belong to the `video` group. If necessary, add the
current user and then log out and back in:

```sh
sudo usermod -aG video "$USER"
```

To load the same loopback device at boot, create
`/etc/modules-load.d/beamicom-v4l2.conf`:

```text
v4l2loopback
```

And create `/etc/modprobe.d/beamicom-v4l2.conf`:

```text
options v4l2loopback devices=1 video_nr=2 card_label="Beamicom Framebuffer" exclusive_caps=1
```

### 4. Run the E2E test

The test starts `BeamicomV4L2.Player` with audio explicitly disabled and the
checked-in Blargg `01.basics.nes` ROM, waits for live emulation, exercises the
control mapping, captures the continuously rendered framebuffer through the
Rust NIF, and compares the recovered image against the emulator output:

```sh
BEAMICOM_V4L2_BUILD=true \
  FRAMEBUFFER=/dev/fb0 \
  VIDEO_OUTPUT=/dev/video-beamicom \
  mix test --include e2e
```

To exercise a user-owned game ROM instead of the checked-in test ROM:

```sh
BEAMICOM_V4L2_BUILD=true \
  BEAMICOM_ROM=/absolute/path/to/game.nes \
  FRAMEBUFFER=/dev/fb0 \
  VIDEO_OUTPUT=/dev/video-beamicom \
  mix test --include e2e
```

At the default scale, this test deliberately overwrites the top-left 768×720
pixels of the visible Linux framebuffer while it runs. The remaining display
is left untouched and is not exported through the Beamicom V4L2 device.

You can also inspect the live stream while the application is running:

```sh
ffplay -f v4l2 /dev/video-beamicom
```

## Precompiled releases

Tags named `beamicom_v4l2-v<VERSION>` run the repository workflow that builds
Linux NIF 2.15 artifacts for x86-64, AArch64, and ARMv7, including GNU and musl
variants where configured. Run the release automation from the repository root:

```sh
bin/release
```

It validates the clean release commit and version, runs the Elixir and Rust
checks, pushes the version tag, waits for the precompiled GitHub artifacts,
generates the mandatory RustlerPrecompiled checksum manifest, and unpacks the
Hex package for inspection. After inspecting it, resume and explicitly publish:

```sh
bin/release --resume --publish
```

The tag is `beamicom_v4l2-v<VERSION>`, where `VERSION` comes from `mix.exs`.
Set `RELEASE_BRANCH` only when intentionally releasing from a branch other than
`main`. Run `bin/release --help` for the complete interface. The script refuses
Hex publication while the core `beamicom` project is a path-only dependency;
publish that package and switch this project to a Hex dependency first.
