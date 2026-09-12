# Resident MMC5 NES frame runner

`NxNes.Machine` runs Castlevania III from its reset vector with the complete PRG
and CHR ROM, RAM, mapper, PPU, APU, controller and CPU state held in Nx tensors.
The compiled frame loop performs CPU execution, device accesses, interrupt
handling, DMA, rendering and audio generation. It makes no host callbacks.
One host call supplies controller masks and advances to the next completed frame.

The existing `Beamicom.NES` production implementation remains native Elixir and
has no Nx/EXLA dependency. This runner lives in the isolated experiment project.
It is functional experimental integration, not yet a real-time replacement.

## Run it

From `experiments/nx_nes`, with the project's Elixir/OTP versions:

```elixir
media = File.read!("../../beamicom/roms/castlevania3.nes")
{:ok, state} = NxNes.Machine.load(media)
run = NxNes.Machine.compile(state, media, entry: 0xE047)
{state, instructions} = run.(state, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
:running = NxNes.Machine.status(state)
%{framebuffer: framebuffer, pcm: pcm, audio_samples: count} = NxNes.Machine.output(state)
# Feed state back to run; only controller masks and output cross the host boundary.
```

The `:entry` option enables a guarded ROM-specialized block at the observed hot
loop. Omitting it still runs the game with the generic interpreter and internal
CPU batching. The loader initializes from the iNES cartridge and reset state;
it does not replay a captured CPU trace or device event recording.

`output/1` returns the same native framebuffer structure that existing RGB/PNG
presentation code understands, plus signed 16-bit little-endian 44.1 kHz mono PCM.
It does not export ROM/RAM or otherwise round-trip emulator state to Elixir.
The application's production UI has not been switched to this experimental path.

## Implemented device integration

- MMC5 PRG modes, ROM/RAM windows, banked WRAM and upper-window RAM protection.
- MMC5 sprite/background CHR modes, ExRAM, nametable selection/fill, split control,
  multiplication registers and scanline IRQ status/acknowledgment.
- PPU register reads/writes, scroll/address latches, buffered data reads, palette
  mirroring, OAM, vblank, odd-frame timing, scanline rendering and frame publication.
- PPU timing before/after CPU memory access, NMI edge/pending state and status-read
  suppression, mapper/APU IRQ polling, and OAM DMA copy/stall/parity.
- Live APU writes/status, base channels, MMC5 audio, PCM filtering and frame output.
- Resident controller strobe/serial reads for both ports.

The native implementation is the differential timing/behavior reference. This
port inherits that implementation's abstractions (including scanline rendering
and its lazy APU IRQ polling), rather than claiming additional hardware accuracy.

## Optimization boundaries

The CPU's arithmetic dispatcher operates on a smaller CPU/memory container.
Device reads occur once before arithmetic and device writes once afterward,
inside Nx. This avoids duplicating the device graphs under every opcode branch.
An initial direct nesting took several minutes to compile; separating the graphs
made the first working frame runner compile in about 17 seconds.

The frame scheduler advances ordinary instructions in resident CPU batches only
while no PPU event or observable interrupt can intervene. A device read/write
barrier or insufficient whole-instruction budget returns control to the fully
timed instruction path **inside the same compiled call**. RAM/mapper/device work
never relies on a native CPU fallback.

A specialized block is additionally guarded by its current mapped ROM bytes and
ROM-backed windows. A self-loop can execute multiple whole iterations before the
next PPU event. Mapping changes, partial blocks, pending interrupts and unusual
code take the generic tensor path. The original native emulator is a separate
application fallback for machines without XLA.

Audio can accumulate while its IRQ is inhibited, but synchronizes before audio
register access and at frame output. When frame IRQ is enabled, the native bus's
100-cycle lazy flush boundary is retained. These batches run the existing Nx
block APU kernel; no native audio loop is used.

## Validation and measurements

The complete experiment suite passes **31 tests**, including the existing
CPU, PPU and APU regressions and new MMC5 register/memory tests plus a full
resident frame test exercising DMA, NMI and guarded instruction batches.

The 902-frame live-ROM validation is in progress; final timing and hashes will
be added after it completes.

`machine_bench.exs` runs the full ROM and separately advances native Elixir as a
comparison oracle after each measured Nx frame. The native core supplies no
state or events to Nx during execution. Checks include CPU/NMI/IRQ state,
RAM/WRAM, mapper registers and banks, PPU control/VRAM/OAM/ExRAM, every framebuffer
pixel and palette byte, audio sample counts, and PCM. APU integer state is exact;
floating state uses an absolute tolerance of 1e-9.

Initial upload, compilation, native-reference execution and comparison exports
are excluded from Nx frame timing. Each timed call synchronizes its result.
The validation run uses a shared, unpinned desktop; it is a baseline for further
profiling, not a controlled hardware benchmark.

```sh
MIX_ENV=prod mix run machine_bench.exs --frames 902 --output results/machine_bench.json
```

The optional process-local scheduling diagnostic from `NX_APU_PROFILE.md`:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run machine_bench.exs \
  --frames 902 --output results/machine_bench_sequential.json
```

The script writes progress, PNG frames, a WAV and a resident-state checkpoint
under ignored `tmp/machine/`. The ROM and those captures are not committed.
`--start-frame N` injects Start for three frames in both implementations.

## Limits and next work

The loader currently accepts MMC5 cartridges with CHR-ROM. Other mappers and
CHR-RAM need their own integrated device paths. Enabling DMC stops explicitly;
DMC playback/DMA and Sunsoft 5B are not implemented here. This is not a claim of
complete NES cartridge compatibility. A failed runner reports a sticky stop
reason, and `output/1` refuses to publish a failed frame.

Only one discovered block is compiled per runner; arbitrary ROM discovery and a
multi-block cache are not implemented. Whole-core performance is still far below
native Elixir. Further profiling should focus on the full scheduler, generic CPU
batches and device-boundary cost using this live workload, while retaining
frame-by-frame correctness checks.
