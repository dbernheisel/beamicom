# Beamicom NES

A cycle-aware NES emulator written in pure Elixir. Its native path has no
external runtime dependencies. The core runs the console and publishes audio/video; how those
frames get drawn or played is left to sink projects, so the emulator itself is
headless.

## Architecture

Beamicom is organized as several projects in one repository:

```
beamicom_nes/      # this project — native and optional Nx renderers
beamicom_host/     # shared system, output, and input contracts
beamicom_scenic/   # desktop client: a Scenic/OpenGL window + ffplay audio
beamicom_stream/   # headless local AV1/Opus RTP client + terminal controls
beamicom_phx/      # web client: streams A/V to the browser over Phoenix
beamicom_v4l2/     # Linux framebuffer and virtual-camera client
```

- [Repository overview](../README.md)
- [Optional Nx renderer design and benchmarks](NX.md)
- [Desktop client](../beamicom_scenic/README.md)
- [Local stream client](../beamicom_stream/README.md)
- [Web client](../beamicom_phx/README.md)

The core produces one `%Beamicom.NES.Framebuffer{}` per PPU frame plus a stream
of APU samples, and fans them out through `Beamicom.NES.Output`, a compatibility
facade over the system-neutral `Beamicom.Host.Output`:

- **Video** is coalesced — sinks read the *latest* frame straight from an ETS
  table (`:read_concurrency`) and drop intermediates. A slow renderer never
  back-pressures the emulation loop.
- **Audio** is a stream — every chunk is encoded once as signed 16-bit
  little-endian PCM and pushed as `{:audio, sample_count, pcm}`. The binary is
  reference-counted across subscribers, and audio chunks are never dropped.

APU waveform rendering has a backend-neutral frame-block boundary. The default
dependency-free Elixir renderer replays timestamped 2A03 and MMC5 operations at
the frame boundary. DMC and Sunsoft 5B remain clocked in the live control state;
their sample-boundary levels are included in the block so mapper timing remains
exact. Optional Nx modules in this package can replace this renderer at compile time.

Both renderers implement `Beamicom.NES.APURenderer`; Nx and its compiler are optional
dependencies. CPU-visible length status, DMC DMA, APU IRQs, and mapper expansion
audio remain in the live native control state for every backend.

### Optional Nx renderers

Applications that want Nx acceleration include Nx and a compiler directly, then
select the compiler and renderer modules in configuration:

```elixir
# mix.exs
{:beamicom_nes, path: "../beamicom_nes"},
{:nx, "~> 1.0"},
{:exla, "~> 1.0"}

# config/config.exs
config :nx, :default_defn_options, compiler: EXLA, client: :host

config :beamicom_nes,
  ppu_renderer: Beamicom.NES.Nx.PPURenderer,
  apu_renderer: Beamicom.NES.Nx.APUBlockRenderer
```

The renderer settings are consumed when `beamicom_nes` compiles. Applications
that omit Nx and its compiler compile
only the native implementation. The Nx PPU performs frame-wide tile and sprite
composition; the block APU batches timestamped 2A03 and MMC5 operations while
the native control state preserves DMC DMA, IRQ, and mapper timing.

For a per-console Blargg NTSC presentation filter, use
`Beamicom.NES.Nx.video_options/2`. Presets include `:composite`, `:svideo`,
`:rgb`, and `:monochrome`.

`Beamicom.NES.Runtime` is the emulation loop (a `GenServer`): it paces frames
from a fixed monotonic epoch so timing error doesn't accumulate, and publishes
fire-and-forget. Sinks subscribe via `Beamicom.NES.Output.subscribe_video/0`,
`subscribe_audio/0`, or `subscribe/0`.

## What's emulated

- **CPU** — 6502 core
- **PPU** — per-scanline rendering
- **APU** — pulse/triangle/noise/DMC, plus MMC5's extra channels
- **Mappers** — 16 mapper numbers are implemented; see the complete
  [supported and unsupported mapper compatibility matrix](MAPPERS.md), including
  board-level limitations and NES 2.0 submapper coverage
- **Input** — two controller ports (`Beamicom.NES.Runtime.set_buttons/3`)

## Usage

The core is headless — for an interactive window, use `beamicom_scenic`. To
drive it directly:

```elixir
{:ok, _} = Beamicom.NES.Runtime.start_link(rom: "roms/game.nes")
Beamicom.NES.Runtime.set_buttons(1, [:a, :start])
Beamicom.NES.Output.latest()   # => %Beamicom.NES.Framebuffer{}
```

### Runtime enhancements

Optional display and PPU enhancements can be enabled at startup or changed
without resetting the running game:

```elixir
{:ok, _} =
  Beamicom.NES.Runtime.start_link(
    rom: "roms/smb3.nes",
    enhancements: [hide_horizontal_overscan: true]
  )

Beamicom.NES.Runtime.set_enhancement(:unlimited_sprites, true)
Beamicom.NES.Runtime.set_enhancement(:hide_horizontal_overscan, false)
```

`:hide_horizontal_overscan` blacks out the leftmost and rightmost eight pixels
while retaining the 256×240 framebuffer. `:unlimited_sprites` renders every
in-range OAM sprite instead of the hardware's first eight per scanline; the PPU
overflow flag continues to report more than eight sprites.

### Terminal input

`Beamicom.TerminalInput` is a reusable Linux terminal adapter for interactive
clients. It accepts callbacks rather than depending on a client project:

```elixir
{:ok, input} =
  Beamicom.TerminalInput.start_link(
    on_buttons: fn port, buttons ->
      Beamicom.NES.Runtime.set_buttons(port, buttons)
    end
  )

Beamicom.TerminalInput.run(input)
```

It uses OTP's native raw terminal mode and parses ANSI arrows plus X/Z, Enter,
and Space. Since standard terminals have no key-up events, held buttons
auto-release unless refreshed by keyboard repeat.

### EI Unix-socket input

The shared [`beamicom_ei`](../beamicom_ei/) project implements the standard
binary EI handshake, device, button, and frame interfaces directly in Elixir:

```elixir
{:ok, server} =
  Beamicom.EI.Server.start_link(
    path: Beamicom.EI.default_path(),
    on_buttons: &Beamicom.NES.Runtime.set_buttons/2
  )

{:ok, client} = Beamicom.EI.Client.start_link(path: Beamicom.EI.default_path())
:ok = Beamicom.EI.Client.await_ready(client)
:ok = Beamicom.EI.Client.set_buttons(client, 1, [:right, :a])
```

### Headless capture (no dependencies needed)

```sh
mix nes.shot roms/game.nes shot.png 60     # render frame 60 to a PNG
mix nes.wav  roms/game.nes out.wav 3        # capture 3s of audio to a WAV
```

## Tests

```sh
mix test
```
