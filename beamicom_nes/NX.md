# Optional NES Nx renderers

These optional modules leave the NES CPU, memory, mapper, PPU timing, and
APU in the native `beamicom_nes` implementation. At each visible scanline the
native PPU resolves mapper-sensitive tile rows, evaluates sprites, and applies status
side effects. The atlas variant records compact CHR row references for both
background tiles and sprites instead of fetching their pattern bytes. At frame
completion this adapter gathers those rows and composes all 240 by 256 palette
addresses in one EXLA CPU call.

Add Nx and EXLA to the client and select the core renderers in compile-time
configuration:

```elixir
{:beamicom_nes, path: "../beamicom_nes"}
{:nx, "~> 1.0"}
{:exla, "~> 1.0"}

config :beamicom_nes,
  ppu_renderer: Beamicom.NES.Nx.PPURenderer,
  apu_renderer: Beamicom.NES.Nx.APUBlockRenderer
```

The values are consumed while `beamicom_nes` is compiled. Changing these
defaults requires recompilation; startup and frame execution never query the
application environment for a backend.

## Opt-in emissive sprite lighting

The Nx PPU renderer can tag exact sprite pattern pixels as emitters and add a
soft, source-colored halo to the resolved RGB frame. The light color comes from
each winning sprite pixel's resolved NES palette entry, so palette animation and
palette swaps automatically tint the halo. This is identity-driven: ordinary
bright pixels never become lights.

```elixir
lighting = [
  radius: 6,
  sigma: 3.0,
  strength: 1.25,
  emitters: [
    [
      layer: :sprite,
      tile_space: :ppu,
      tiles: zelda_emissive_sprite_tiles,
      subpalettes: [1, 2],
      color_slots: [2, 3],
      intensity: 1.0,
      flicker: :organic
    ]
  ]
]

options = [
  ppu_renderer: {Beamicom.NES.Nx.PPURenderer, lighting: lighting}
]

{:ok, console} = Beamicom.NES.System.load(rom, options)
```

Use `tile_space: :chr` for a physical tile number in immutable CHR ROM. Use
`:ppu` for the logical PPU pattern-table tile number from 0 through 511; this is
the useful identity for CHR-RAM games such as The Legend of Zelda. Rules can
also constrain the two-bit sprite subpalette and the nontransparent pattern
color slots 1 through 3. Several rules may target different object groups or
use different intensities. Flicker is opt-in per rule: `flicker: :organic` uses
a restrained 18% variation, while `flicker: [amount: 0.3]` or a numeric value
from `0.0` through `1.0` controls its depth. The waveform combines three
incommensurate temporal frequencies with a position-derived phase, so nearby
pixels remain coherent while separate emitters do not pulse in lockstep. It is
derived only from the emulated frame number and screen position, making replay
and save-state output deterministic.

`Beamicom.NES.Nx.Lighting` includes a verified profile for the US Zelda ROM with
parsed PRG+CHR SHA-256
`085e5397a3487357c263dfa159fb0fe20a5f3ea8ef82d7af6a7e848d3b9364e8`:

```elixir
rom = File.read!("roms/zelda.nes")
{:ok, lighting} = Beamicom.NES.Nx.Lighting.for_rom(rom)

native = [
  ppu_renderer: {Beamicom.NES.Nx.PPURenderer, lighting: lighting}
]

composite = Beamicom.NES.Nx.video_options(:composite, lighting: lighting)
```

The observed CHR-RAM identities are tiles 92-95, subpalette 2, color slots 2-3
for the flame's yellow/white core; tiles 130-133, every animated subpalette,
color slot 3 for the sword blade and traveling beam; and tiles 48-49, every
animated subpalette, color slot 3 for the four beam-burst particles. The flame
uses deterministic organic flicker. Additional verified emitters are rupee tiles
50-51 in flashing subpalettes 1-2 at 60% intensity; Link tiles 0-19 only in the clock-flash
subpalettes 1-2; enemy-fireball tiles 68-69 across all four animated
subpalettes; and heart-pickup tiles 498-499 in flashing subpalettes 1-2. These
use color slots 2-3 except for the single-color heart pattern, which uses slot
1. Normal Link uses subpalette 0 and therefore remains non-emitting. The other
pixels in those sprites remain non-emitting, although they can still receive the
nearby halo.

The Blargg renderer keeps the identity-derived emissive plane at native
resolution, applies the selected NTSC filter, and adds the resampled halo to the
602x240 presentation. Lighting therefore composes with Composite, S-Video, RGB,
and Monochrome instead of replacing them. Removing the sprite limit retains a
compact winning-sprite provenance plane from native composition, so covered or
lower-priority sprite pixels still cannot emit. Horizontal trimming masks both
the filtered picture and the halo.

Run the optional real-ROM checkpoint test with:

```console
BEAMICOM_NX=1 BEAMICOM_ZELDA_STATE=/path/to/zelda-state.png \
  mix test nx_test/nes/zelda_lighting_e2e_test.exs
```

The test validates the ROM-content and checkpoint hashes, exercises all twenty
filter/enhancement combinations, and advances the checkpoint through the sword,
traveling beam, and four-particle burst. It is skipped when the external ROM or
checkpoint is unavailable.

Optional supplemental checkpoint coverage uses
`BEAMICOM_ZELDA_RUPEE_STATE`, `BEAMICOM_ZELDA_CLOCK_STATE`,
`BEAMICOM_ZELDA_FIREBALL_STATE`, and `BEAMICOM_ZELDA_HEART_STATE`. When all four
are present, the suite verifies their hashes, sprite identities, unchanged
palette-address planes, and localized RGB emission.

Lighting changes only the optional RGB presentation. The native 256×240
palette-address plane, PPU priority, sprite clipping, and emulation state remain
unchanged. With no matching emitter, RGB output is byte-for-byte identical to
the unlit Nx renderer. The active RGB field is averaged to half resolution and
blurred as one batched, dense, separable Gaussian, so its cost is bounded by
frame size and radius rather than growing with the number of emitting pixels.

## Runtime Blargg NTSC filter

The Blargg-compatible Nx filter can instead be selected for each loaded console,
without changing the compiled default:

```elixir
options = Beamicom.NES.Nx.video_options(:composite)
{:ok, console} = Beamicom.NES.System.load(rom, options)
```

The presets are `:composite`, `:svideo`, `:rgb`, and `:monochrome`. Setup values
such as `merge_fields: false`, `hue: 0.1`, or `artifacts: -0.25` can be passed as
the second argument to `video_options/2`. The native 256×240 palette-address
plane remains available in each framebuffer; the shared filtered presentation
is RGB24 at 602×240. Square-pixel hosts should double its scanlines.

The runtime path keeps the generated reference table byte-exact, then stores a
flat signed-32-bit copy on EXLA. All possible six-tap sums for the standard
presets fit signed 32-bit, so this halves kernel and index bandwidth without
changing output; extreme custom setups automatically retain 64-bit storage. The
Blargg renderer also reuses the general Nx compositor's palette plane and
scanline-mask tensor instead of expanding an unused native RGB frame or
repacking masks.

Benchmark a preset through the same full-system harness as the native and Nx
renderers:

```console
mix nes.bench roms/castlevania3.nes --seconds 15 \
  --repeats 3 --video-filter composite
```

It implements the same `Beamicom.NES.APURenderer` callbacks as the core's pure
Elixir `Beamicom.NES.APUBlockRenderer`. Switching implementations changes only
the configured module; event capture, DMC timing, frame output, and save-state
handling are shared.

```console
mix nes.bench roms/castlevania3.nes --seconds 15 \
  --renderer nx --audio-renderer nx_block --rgb-consumers 3
```

The dependency-free Elixir block renderer remains the default when Nx and EXLA
are absent.

## Current result

The 902-frame (15.009 emulated seconds) Castlevania III run is exact: the native
and Nx paths produced the same RGB and audio SHA-256 hashes. On the EXLA CPU
client used for the initial measurement, pure native emulation ran at 88.06 FPS
and the initial palette-address-only Nx adapter at 79.14 FPS. The narrow kernel
does not improve single-instance CPU throughput by itself.

When the benchmark includes the three RGB consumers used by Scenic, V4L2, and
streaming, native runs at 66.54 FPS and the shared Nx RGB result runs at 77.83
FPS. Deferring palette expansion and doing it once in the frame kernel therefore
improves this three-sink workload by 17.0%.

The Nx renderer expands immutable CHR ROM into a resident tile atlas at
cartridge load. Deferring both background and sprite pattern fetches raised the
median full fifteen-second Castlevania III result to 79.09 FPS. That was 18.9%
faster than native with three RGB consumers and 1.6% faster than the earlier Nx
byte-only prototype. The prototype is no longer exposed as a separate renderer;
the unified Nx path falls back to byte or hybrid capture for mutable and
latch-driven CHR.

PPU status timing and mapper-visible effects remain native even when visual work
moves into the adapter. CHR RAM and latch-driven cartridges automatically use
the byte-capture path.

The block APU retains oscillator and filter state on EXLA. The native bus records
timestamped 2A03 and MMC5 register operations and continues to maintain
frame/DMC IRQs, length status, DMC DMA, and Sunsoft 5B timing. For DMC and
Sunsoft 5B playback it sends one resolved level per output sample, keeping the
compiled mixer exact without placing variable-length mapper or DMA state in the
graph. Mapper 5 and mapper 69 cartridges therefore use the same Nx block path.

The PPU and APU programs execute concurrently at the frame output boundary. In
the latest three repeated 902-frame Castlevania III runs, the combined
`nx` + `nx_block` path produced identical RGB and PCM hashes at a median
**112.37 FPS** (110.53–113.80). The dependency-free block build reached 64.17
FPS (64.04–64.41) with the same three RGB consumers. The renderer also survives
save-state snapshot and restore with its resident state reconstructed on EXLA.

The dependency-free Elixir block renderer produces the same Castlevania III PCM
and framebuffer hashes. With a native PPU it reaches 65.69 FPS versus 66.54 FPS
for inline audio, a 1.3% boundary cost. Paired with the deferred Nx atlas PPU it
reaches 102.52 FPS because Elixir audio replay overlaps the PPU program. The Nx
APU raises that to the 107.94 FPS median above through vector waveform synthesis.
