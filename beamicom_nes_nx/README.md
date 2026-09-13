# Beamicom NES Nx

This optional application leaves the NES CPU, memory, mapper, PPU timing, and
APU in the dependency-free `beamicom_nes` application. At each visible scanline the native
PPU resolves mapper-sensitive tile rows, evaluates sprites, and applies status
side effects. The atlas variant records compact CHR row references for both
background tiles and sprites instead of fetching their pattern bytes. At frame
completion this adapter gathers those rows and composes all 240 by 256 palette
addresses in one EXLA CPU call.

Add `beamicom_nes_nx` and select its renderers in the client's compile-time
configuration:

```elixir
{:beamicom_nes_nx, path: "../beamicom_nes_nx"}

config :beamicom_nes,
  ppu_renderer: Beamicom.NES.Nx.PPUAtlasRenderer,
  apu_renderer: Beamicom.NES.Nx.APUBlockRenderer
```

The values are consumed while `beamicom_nes` is compiled. Changing them
requires recompilation; startup and frame execution never query the application
environment for a backend.

It implements the same `Beamicom.NES.APURenderer` callbacks as the core's pure
Elixir `Beamicom.NES.APUBlockRenderer`. Switching implementations changes only
the configured module; event capture, DMC timing, frame output, and save-state
handling are shared.

```console
mix nes.bench ../beamicom_nes/roms/castlevania3.nes --seconds 15 \
  --renderer nx_atlas --audio-renderer nx_block --rgb-consumers 3
```

The dependency-free Elixir block renderer remains the default when
`beamicom_nes_nx` is absent and requires neither Nx nor EXLA.

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

The optional `nx_atlas` renderer expands immutable CHR ROM into a resident tile
atlas at cartridge load. Deferring both background and sprite pattern fetches
raises the median full fifteen-second Castlevania III result to 79.09 FPS. That
is 18.9% faster than native with three RGB consumers and 1.6% faster than the Nx
byte renderer. The byte renderer remains the default because it also handles
mutable and latch-driven CHR directly; the atlas path falls back to byte capture
for those cartridges.

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
`nx_atlas` + `nx_block` path produced identical RGB and PCM hashes at a median
**112.37 FPS** (110.53–113.80). The dependency-free block build reached 64.17
FPS (64.04–64.41) with the same three RGB consumers. The renderer also survives
save-state snapshot and restore with its resident state reconstructed on EXLA.

The dependency-free Elixir block renderer produces the same Castlevania III PCM
and framebuffer hashes. With a native PPU it reaches 65.69 FPS versus 66.54 FPS
for inline audio, a 1.3% boundary cost. Paired with the deferred Nx atlas PPU it
reaches 102.52 FPS because Elixir audio replay overlaps the PPU program. The Nx
APU raises that to the 107.94 FPS median above through vector waveform synthesis.
