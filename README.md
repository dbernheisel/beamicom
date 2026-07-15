# Beamicom

A cycle-aware NES emulator written in pure Elixir, with **zero external
dependencies**. The core runs the console and publishes audio/video; how those
frames get drawn or played is left to sink projects, so the emulator itself is
headless.

## Architecture

Three projects, cloned as siblings:

```
~/beamicom          # this project — the core emulator (headless)
~/beamicom_scenic   # desktop client: a Scenic/OpenGL window + ffplay audio
~/beamicom_phx      # web client: streams A/V to the browser over Phoenix
```

- Core: https://github.com/dbernheisel/beamicom
- Desktop client: https://github.com/dbernheisel/beamicom_scenic
- Web client: https://github.com/dbernheisel/beamicom_phx

The core produces one `%Beamicom.NES.Framebuffer{}` per PPU frame plus a stream
of APU samples, and fans them out through `Beamicom.NES.Output`:

- **Video** is coalesced — sinks read the *latest* frame straight from an ETS
  table (`:read_concurrency`) and drop intermediates. A slow renderer never
  back-pressures the emulation loop.
- **Audio** is a stream — every chunk is pushed to subscribers as `{:audio, samples}`,
  because audio can't drop samples without an audible gap.

`Beamicom.NES.Runtime` is the emulation loop (a `GenServer`): it paces frames
from a fixed monotonic epoch so timing error doesn't accumulate, and publishes
fire-and-forget. Sinks subscribe via `Beamicom.NES.Output.subscribe_video/0`,
`subscribe_audio/0`, or `subscribe/0`.

## What's emulated

- **CPU** — 6502 core
- **PPU** — per-scanline rendering
- **APU** — pulse/triangle/noise/DMC, plus MMC5's extra channels
- **Mappers** — 0 NROM, 1 MMC1, 2 UxROM, 3 CNROM, 4 MMC3, 5 MMC5, 7 AxROM,
  9 MMC2 / 10 MMC4, 11 Color Dreams / 66 GxROM, 69 Sunsoft FME-7
- **Input** — two controller ports (`Beamicom.NES.Runtime.set_buttons/3`)

## Usage

The core is headless — for an interactive window, use `beamicom_scenic`. To
drive it directly:

```elixir
{:ok, _} = Beamicom.NES.Runtime.start_link(rom: "roms/game.nes")
Beamicom.NES.Runtime.set_buttons(1, [:a, :start])
Beamicom.NES.Output.latest()   # => %Beamicom.NES.Framebuffer{}
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
