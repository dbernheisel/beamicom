# Beamicom GBC

A headless Game Boy and Game Boy Color emulator core written in Elixir. Its
native path is dependency-free. This project is intentionally separate from the NES core: hardware
timing and machine state remain system-specific, while `beamicom_host` provides
shared coarse-grained video, input, and lifecycle boundaries.

## Optional Nx renderers

The package also contains frame-wide PPU and block APU renderers backed by Nx
and EXLA. A consuming application opts in by including those optional
dependencies directly and selecting the modules before the core compiles:

```elixir
# mix.exs
{:beamicom_gbc, path: "../beamicom_gbc"},
{:nx, "~> 1.0"},
{:exla, "~> 1.0"}

# config/config.exs
config :beamicom_gbc,
  ppu_renderer: Beamicom.GB.Nx.PPURenderer,
  apu_renderer: Beamicom.GB.Nx.APUBlockRenderer
```

Native-only consumers omit Nx and EXLA, and the optional modules are not
compiled. Renderer selection is fixed at compile time. The PPU graph receives
frame-start VRAM, OAM, palette RAM, scanline controls, and timestamped visible
writes, then performs tile lookup and sprite evaluation for the 160×144 frame.
`Beamicom.GB.Nx.APUSynthRenderer` remains available for full event-block audio
synthesis; the default Nx APU renderer batches resolved channel levels.

See [the Nx renderer design and benchmarks](NX.md) for payload details and
measured single-instance results.

The first milestone provides:

- Game Boy cartridge-header parsing with checksum validation
- DMG, CGB-compatible, and CGB-only identification
- Standard cartridge type and ROM/RAM size metadata
- Fixed two-bank ROM access for no-MBC cartridges
- External RAM access for no-MBC RAM cartridges
- A functional SM83/LR35902 CPU with all legal base and CB opcodes
- Cycle-ordered bus accesses with exact per-instruction M-cycle counts
- Interrupt priority/service, delayed IME, HALT/HALT-bug, and STOP behavior
- DIV/TIMA timer edges, delayed overflow reload, and interrupt registers
- CGB KEY1 normal/double-speed switching
- A mapped hardware bus with an explicitly separate flat CPU-test path
- Separate DMG and CGB background, window, and sprite rendering at 160×144
- CGB tile attributes, dual-bank VRAM, RGB555 palettes, and RGB24 frame output
- Four-channel DMG/CGB audio with sweep, length/envelope sequencing, stereo
  routing, and deterministic 44.1 kHz signed-16 PCM
- Dependency-free PNG screenshots for CGB RGB24 and DMG palette output
- Versioned, self-contained save-state PNGs with a visible data border and
  SHA-256 cartridge identity validation

ROM-only cartridges and MBC1, MBC2, MBC3, and MBC5 are implemented. This
includes banked/paged save RAM, MBC2 nibble RAM, deterministic MBC3 RTC
advancement/latching, persistence import/export, and MBC5's nine-bit ROM bank.
MMM01, MBC6, MBC7, Pocket Camera, Bandai Tama5, HuC1, and HuC3 are identified
in header metadata but are not emulated yet.

The CPU and bus remain separate. Every CPU fetch, data read/write, and internal
idle M-cycle advances timer hardware before the next observable bus access.
The Bus owns the sole PPU and APU instances and converts those CPU clocks to
base hardware dots, preserving LCD and audio duration in CGB double speed. One
instruction can be executed headlessly with:

```elixir
alias Beamicom.GB.{Bus, CPU}

bus = Bus.new(<<0x3E, 0x42>>) # LD A,$42
{cpu, bus, 2} = CPU.step(CPU.new(), bus)
cpu.a
```

## Usage

```elixir
{:ok, cartridge} = Beamicom.GB.Cartridge.load(File.read!("game.gbc"))
byte = Beamicom.GB.Cartridge.read(cartridge, 0x0100)
```

To inspect the header of a cartridge whose mapper is not implemented:

```elixir
{:ok, header} = Beamicom.GB.Header.parse(File.read!("game.gbc"))
header.mapper
```

Capture a screenshot after a selected number of frames. Cartridge headers
select DMG or CGB rendering automatically; the final palette argument applies
only to DMG shade-index frames:

```sh
mix gb.shot game.gb screenshot.png 60 dmg_green
mix gb.shot game.gbc screenshot-color.png 60
```

The repository's self-authored diagnostic ROM can be generated without any
commercial game data:

```elixir
File.write!("diagnostic.gb", Beamicom.GB.DiagnosticROM.build())
File.write!("diagnostic.gbc", Beamicom.GB.DiagnosticROM.build_cgb())
```

Both are real ROM programs. Their SM83 code disables the LCD and configures
video through the mapped bus before turning it back on. The CGB diagnostic also
writes both VRAM banks, attribute maps and color palettes, and transfers sprites
with OAM DMA. They are used by the end-to-end screenshot tests.

To create and restore a shareable save image from a frame boundary:

```elixir
alias Beamicom.GB.{ShareImage, System}

{machine, [video, _audio]} = System.run_slice(machine)
png = ShareImage.to_png(machine, video.data)
{:ok, restored_machine} = ShareImage.load_image(png)
```

The screenshot is nearest-neighbor enlarged to 640×576 and centered inside a
visible, CRC-protected dot-code border. The border holds the compressed,
ROM-stripped machine state. The immutable ROM is stored after PNG IEND for
exact file transfer and is verified against the state's byte length and SHA-256
digest before restoration. `load_image/2` can recover a stripped trailer from
matching `.gb` or `.gbc` files in explicitly supplied search directories.

## Known timing limitations

PPU mode 3 includes the documented fine-scroll, window, and object-fetch FIFO
penalties. Pixel composition remains scanline-granular, so mid-scanline register
effects are not timing-visible. CGB STOP speed switching toggles speed immediately
at the instruction boundary. Hardware pauses the CPU for roughly 2050 M-cycles
and freezes parts of the PPU differently by LCD mode; that oscillator transition
is intentionally deferred until those clock-domain effects can be represented
together.

The APU models digital register/channel behavior but not the analog high-pass
filter, capacitor state, DAC pops, envelope zombie behavior, sweep-negate
clearing, or model-specific wave-RAM access/corruption while channel 3 is
active. CGB PCM amplitude registers FF76 and FF77 are also deferred until the
internal mixer levels are exposed.

## Tests

The tests generate synthetic ROM images and do not include commercial ROM
data.

```sh
mix test
```
