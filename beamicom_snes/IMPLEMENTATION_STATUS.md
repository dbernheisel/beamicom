# SNES implementation status

This is a source audit of the native SNES core. It is intended to answer two
questions:

1. Which CPU instructions, PPU/APU registers, and cartridge coprocessors are
   represented today?
2. Which correctness work should remain scalar/native, and which hot paths are
   plausible Nx/EXLA workloads?

Status legend:

- **Implemented**: a dispatch path and the main behavior exist.
- **Partial**: usable behavior exists, but documented hardware semantics are
  missing or knowingly approximate.
- **Missing**: no functional implementation exists.
- **Lightly validated**: static dispatch is present, but the tests do not prove
  conformance across modes, boundaries, flags, or timing.

The audit describes the current source, not a cycle-accuracy claim.

## Executive summary

| Area | Current coverage | Highest-priority gaps |
|---|---|---|
| W65C816S CPU | **256/256 opcode bytes**, 92/92 mnemonics | Addressing carry/wrap and cycle rules; broader conformance validation |
| Interrupts | NMI/IRQ/BRK/COP entry, WAI wakeup, and RTI implemented | ABORT/reset sequencing and instruction-boundary IRQ quirks |
| PPU MMIO | Most write paths from `$2100-$2133`; selected reads | OAM/VRAM read semantics, counters/status, hires/interlace, raster timing |
| PPU modes | Native paths for modes 0-7; modes 2-6 are partial | OPT, true/pseudo-hires, interlace pixels, OBJ edge cases |
| SPC700 | **256/256 opcode bytes**, lightly validated | Exact instruction/MMIO timing and conformance tests; fragmented-cycle debt is handled |
| S-SMP | Ports, IPL overlay, timers, DSP address/data mostly present | TEST semantics, timer phase, DSPDATA write behavior, real IPL execution |
| S-DSP | Basic eight-voice BRR playback, stereo mixing, and register-event-ordered output | ADSR/GAIN, interpolation, PMON/noise, echo/FIR |
| Cartridge coprocessors | **Partial Cx4** | Cx4 sprite/transform/wireframe commands; common interface and SuperFX |
| Nx/EXLA | Optimized subsets of Mode 1 and Mode 7 | Broader fused PPU kernels; later block-based DSP mixing |

## W65C816S CPU instruction inventory

The interpreter's opcode fallback remains explicit for defensive diagnostics.
Static expansion of the dispatch tables recognizes all 256 byte values.

For the six large ALU/load families below, opcode order is:

`(dp,X), sr,S, dp, [dp], #imm, abs, long, (dp),Y, (dp), (sr,S),Y, dp,X, [dp],Y, abs,Y, abs,X, long,X`

| Status | Instruction | Opcode bytes |
|---|---|---|
| Implemented | ORA | `01 03 05 07 09 0D 0F 11 12 13 15 17 19 1D 1F` |
| Implemented | AND | `21 23 25 27 29 2D 2F 31 32 33 35 37 39 3D 3F` |
| Implemented | EOR | `41 43 45 47 49 4D 4F 51 52 53 55 57 59 5D 5F` |
| Implemented | ADC | `61 63 65 67 69 6D 6F 71 72 73 75 77 79 7D 7F` |
| Implemented | CMP | `C1 C3 C5 C7 C9 CD CF D1 D2 D3 D5 D7 D9 DD DF` |
| Implemented | SBC | `E1 E3 E5 E7 E9 ED EF F1 F2 F3 F5 F7 F9 FD FF` |
| Implemented | LDA | `A1 A3 A5 A7 A9 AD AF B1 B2 B3 B5 B7 B9 BD BF` |
| Implemented | STA | `81 83 85 87 8D 8F 91 92 93 95 97 99 9D 9F` |
| Implemented | LDX/STX | `A2 A6 AE B6 BE` / `86 8E 96` |
| Implemented | LDY/STY | `A0 A4 AC B4 BC` / `84 8C 94` |
| Implemented | STZ | `64 74 9C 9E` |
| Implemented | CPX/CPY | `E0 E4 EC` / `C0 C4 CC` |
| Implemented | ASL/ROL/LSR/ROR | `0A 06 0E 16 1E` / `2A 26 2E 36 3E` / `4A 46 4E 56 5E` / `6A 66 6E 76 7E` |
| Implemented | INC/DEC | `1A E6 EE F6 FE` / `3A C6 CE D6 DE` |
| Implemented | BIT/TSB/TRB | `24 2C 34 3C 89` / `04 0C` / `14 1C` |
| Implemented | BPL/BMI/BVC/BVS | `10 30 50 70` |
| Implemented | BCC/BCS/BNE/BEQ | `90 B0 D0 F0` |
| Implemented | BRA/BRL | `80 82` |
| Implemented | JMP/JML | `4C 6C 7C DC 5C` |
| Implemented | JSR/JSL | `20 FC 22` |
| Implemented | RTS/RTL/RTI | `60 6B 40` |
| Implemented | CLC/SEC, CLI/SEI, CLV/CLD/SED | `18 38`, `58 78`, `B8 D8 F8` |
| Implemented | REP/SEP/XCE | `C2 E2 FB` |
| Implemented | TAX/TAY/TXA/TYA | `AA A8 8A 98` |
| Implemented | TSX/TXS/TXY/TYX | `BA 9A 9B BB` |
| Implemented | TCS | `1B` |
| Implemented | TSC/TCD/TDC | `3B 5B 7B` |
| Implemented | DEX/DEY/INX/INY | `CA 88 E8 C8` |
| Implemented | PHP/PHA/PHK/PHY/PHB/PHX/PHD | `08 48 4B 5A 8B DA 0B` |
| Implemented | PLP/PLA/PLY/PLB/PLX/PLD | `28 68 7A AB FA 2B` |
| Implemented | PEA/PEI/PER | `F4 D4 62` |
| Implemented | MVP/MVN | `44 54` |
| Implemented | NOP/XBA/WDM | `EA EB 42` |
| Implemented | BRK/COP | `00 02` |
| Implemented | WAI/STP | `CB DB` |

The broad family decoders include
[`cpu.ex:1017`](lib/beamicom/snes/cpu.ex#L1017). "Implemented" above means that
the instruction dispatches. Notable completed behavior and remaining shared
gaps are:

- ADC/SBC implement native binary and staged 8/16-bit BCD paths; exhaustive
  valid packed-BCD byte tests cover results and C/Z/N, with focused overflow
  and 16-bit cases.
- Absolute indexed and indirect indexed address calculation loses bank carry.
- Emulation-mode direct-page wrapping rules are incomplete.
- Direct-page, page-cross, indexed-store, and 16-bit-index cycle penalties are
  incomplete.
- Sixteen-bit second-byte wrapping uses one rule where the hardware varies by
  addressing mode.
- TCS preserves stack page `$01` in emulation mode and transfers all 16 bits in
  native mode.

NMI has priority over IRQ, IRQ masking works, native/emulation and BRK/COP
vectors are selected, WAI wakes for masked IRQ and vectors for accepted
interrupts, and RTI restores the appropriate state. STP is explicit and only a
reset may restart it. Remaining gaps include ABORT, runtime reset sequencing,
and IRQ polling-delay quirks around CLI/SEI/PLP/RTI.

## PPU register inventory

Unhandled PPU writes fall through unchanged at
[`ppu.ex:385`](lib/beamicom/snes/ppu.ex#L385); unhandled reads return open-bus
data at [`ppu.ex:397`](lib/beamicom/snes/ppu.ex#L397).

| Register | Status | Implemented behavior and gaps |
|---|---|---|
| `$2100` INIDISP | Partial | Forced blank and brightness work. Mid-scanline changes are preserved only when scanline-state capture is enabled. |
| `$2101` OBSEL | Partial | Base/name selection, palette, priority, flips, and six square size pairs work. Rectangular size modes 6/7 and OBJ interlace do not. |
| `$2102-$2104` OAMADD/OAMDATA | Partial | Word addressing, low-table write latch/pair commit, high-table mirroring, vblank reset, and priority rotation work. Active-display behavior and exact internal-address rotation updates remain. |
| `$2105` BGMODE | Partial | Mode and priority tables exist for modes 0-7; mode-specific gaps are listed below. |
| `$2106` MOSAIC | Implemented | Native 1x1 through 16x16 screen-aligned sampling, independent BG enables, scanline-state persistence, and Mode 7 EXTBG split-axis behavior. Exact mid-block size changes remain approximate. Active mosaic currently selects native fallback. |
| `$2107-$210A` BGnSC | Implemented | Basic tilemap bases and sizes. |
| `$210B-$210C` BGnNBA | Implemented | Basic character-data bases. |
| `$210D-$2114` BGnHOFS/BGnVOFS | Partial | Scroll and shared Mode 7 latch work. OPT and pixel/dot-granular raster effects do not. |
| `$2115-$2119` VMAIN/VMADD/VMDATA | Partial | Increment and remap work. VRAM prefetch/read buffer, access restrictions, and exact open-bus behavior do not. |
| `$211A-$2120` M7SEL/matrix/center | Implemented | Matrix writes, multiply result, affine flips/repeat/fill, and tile-zero fill. Rendering remains scanline/frame-granular. |
| `$2121-$2122` CGADD/CGDATA | Partial | 15-bit palette reads/writes work. Active-display restrictions and open-bus high-bit details do not. |
| `$2123-$212B` windows | Implemented | Layer selection, positions, and OR/AND/XOR/XNOR combination. |
| `$212C-$212F` screen designation | Implemented | Main/sub screen and their window masks. |
| `$2130-$2132` color math | Partial | Add/subtract, fixed color, subscreen, direct color, and window paths exist. Native OBJ palette gating and add-half saturation order are inaccurate. |
| `$2133` SETINI | Partial | Interlace timing, overscan, and EXTBG are stored. Pseudo-hires, OBJ interlace, external sync, and interlaced pixels are absent. |
| `$2134-$2136` MPY | Implemented | Mode 7 multiplication result. |
| `$2137` SLHV | Missing | No H/V counter latch. |
| `$2138` OAMDATAREAD | Partial | Reads and increments through low OAM and the mirrored high table. Display-time behavior and open-bus details remain. |
| `$2139-$213A` VMDATAREAD | Partial | Reads exist without the required prefetch/buffer semantics. |
| `$213B` CGDATAREAD | Partial | Basic read exists; latch/open-bus details are incomplete. |
| `$213C-$213D` OPHCT/OPVCT | Missing | No latched H/V counter reads. |
| `$213E-$213F` STAT77/STAT78 | Partial | Constant placeholders only; range/time-over, field, region, latch state, and distinct PPU open buses are absent. |

### Rendering modes and related features

| Feature | Status |
|---|---|
| Mode 0 | Native four-layer 2bpp rendering, priorities, and palette partition implemented. |
| Mode 1 | Native implemented, including BG3 priority. Nx supports a restricted 8x8-tile path. |
| Mode 2 | Partial native 4bpp layers; BG3 offset-per-tile is missing. |
| Mode 3 | Native 8bpp BG1 + 4bpp BG2 and direct color implemented. |
| Mode 4 | Partial native bit depths/priorities/direct color; offset-per-tile missing. |
| Mode 5 | Partial 256-wide approximation; true 512-wide hires, 16x8 semantics, and vertical interlace resolution missing. |
| Mode 6 | Partial native BG1/priorities; hires and offset-per-tile missing. |
| Mode 7 | Native and Nx affine rendering, direct color, repeat/fill/flips, and EXTBG priorities implemented; no per-dot effects. |
| BG tiles | 2/4/8bpp decode, 8x8/16x16 groups, and tilemap sizes implemented. |
| OBJ | 128 entries, 32 sprites/line, 4bpp palettes, flips, priorities, name selection, and priority rotation including scanline capture. Missing 34-sliver limit/flags, rectangular sizes, and interlace. |
| Windows/color math | Broadly implemented with the accuracy gaps above. |
| Mosaic | Native implementation for modes 0-7; active mosaic currently falls back from Nx. |
| Hires/pseudo-hires/interlaced pixels | Missing. |

Timing includes NTSC/PAL scanline lengths, NTSC short and PAL long lines,
vblank selection, NMI, and H/V IRQs. Missing or approximate pieces include the
40-master-clock DRAM refresh stall, PPU access contention, CPU-written raster
state capture, DMA byte-level timing, HDMA clocks/stalls, overscan-aware HDMA,
and B-to-A read side effects.

## APU inventory

### SPC700 instructions

All 256 byte values reach an `execute/2` clause. This is complete static opcode
dispatch but only lightly validated.

| Family | Implemented instructions |
|---|---|
| Branches | BPL, BMI, BVC, BVS, BCC, BCS, BNE, BEQ, BRA |
| Status/control | CLRP, SETP, CLRC, SETC, EI, DI, CLRV, NOTC, NOP, BRK |
| MOV | All A/X/Y immediate, direct, indexed, indirect, absolute, register-transfer, memory-memory, and `(X)+` forms |
| 8-bit ALU | OR, AND, EOR, CMP, ADC, SBC accumulator and memory forms |
| Compare/index | CMP X and CMP Y forms |
| Shift/RMW | ASL, ROL, LSR, ROR, INC, DEC accumulator and memory forms |
| 16-bit YA | MOVW, INCW, DECW, CMPW, ADDW, SUBW |
| Calls/jumps/returns | CALL, PCALL, all 16 TCALLs, RET, RETI, JMP absolute and indexed-indirect |
| Stack | PUSH/POP PSW, A, X, Y |
| Loop/test branches | DBNZ Y, DBNZ dp, CBNE dp, CBNE dp+X |
| Memory-bit | SET1, CLR1, BBS, BBC, TSET1, TCLR1 |
| Carry-bit | OR1, AND1, EOR1, MOV1 C/bit, NOT1 |
| Arithmetic specials | MUL, DIV, XCN, DAA, DAS |
| Halt | SLEEP, STOP |

The dispatch starts at
[`spc700.ex:80`](lib/beamicom/snes/spc700.ex#L80). SLEEP and STOP cycle counts
are inaccurate, instruction memory effects are not cycle-positioned, opcode
fetch bypasses the MMIO-aware read path, and the test suite is not exhaustive.

### SPC fragmented-cycle accounting

This audit found that an earlier `SPC700.run/2` discarded instruction overshoot,
allowing repeated tiny `$2140-$2143` port flushes to overclock the SPC. The
current implementation stores a signed `cycle_credit`: a complete instruction
may create negative debt, and later grants pay it down before another opcode
executes. Fragmented-versus-batched SPC and APU tests now cover this behavior.

### S-SMP registers

| Register | Status | Notes |
|---|---|---|
| `$F0` TEST | Missing | Clock scaling, RAM-write disable, and timer controls ignored. |
| `$F1` CONTROL | Partial | Timer enables, input-port clear, and IPL visibility exist; enabling incorrectly resets timer stage-one phase. |
| `$F2` DSPADDR | Implemented | Address latch. |
| `$F3` DSPDATA | Partial | Reads mask bit 7 and writes ignore addresses `$80-$FF`; exact access timing remains approximate. |
| `$F4-$F7` CPUIO | Partial | Directional latches and clear controls work; same-cycle collision behavior absent. |
| `$F8-$F9` AUX | Implemented | Auxiliary RAM values. |
| `$FA-$FC` timer targets | Partial | Zero-as-256 works; write-only read behavior is inaccurate. |
| `$FD-$FF` timer outputs | Partial | Four-bit wrap and clear-on-read work; edge timing is approximate. |
| `$FFC0-$FFFF` IPL overlay | Partial | Correct 64-byte image exists, but normal boot uses a high-level upload state machine and jumps directly to the upload entry point. |

### S-DSP registers and synthesis

Per-voice register groups `$x0-$x9` apply to voices 0-7.

| Register/feature | Status |
|---|---|
| `VOLL/VOLR $x0/$x1` | Implemented |
| `PITCHL/PITCHH $x2/$x3` | Partial: nearest-neighbor sampling only |
| `SRCN $x4`, `DIR $5D` | Implemented |
| BRR decode, filters 0-3, end/loop | Partial approximation |
| `ADSR1/ADSR2 $x5/$x6` | Missing |
| `GAIN $x7`, all gain modes | Missing |
| `ENVX $x8`, `OUTX $x9` | Missing; generic storage only |
| `MVOLL/MVOLR $0C/$1C` | Implemented |
| `EVOLL/EVOLR $2C/$3C` | Missing |
| `KON $4C` | Partial: block-latched without DSP pipeline/start delay |
| `KOFF $5C` | Partial: kills voices instead of entering release |
| `FLG $6C` | Partial mute/reset; noise clock missing |
| `ENDX $7C` | Partial: looping end blocks do not set ENDX correctly |
| `EFB $0D` | Missing |
| `PMON $2D` | Missing |
| `NON $3D` | Missing |
| `EON $4D` | Missing |
| `ESA $6D`, `EDL $7D` | Missing |
| FIR coefficients `$0F-$7F` | Missing |
| Gaussian interpolation | Missing |
| Echo RAM writes and eight-tap FIR | Missing |
| Exact 32-cycle DSP pipeline | Missing |

`APU.advance/3` now timestamps DSP writes against SPC cycles and renders blocks
between those events. Intermediate KON/KOFF, pitch, volume, directory, and
mixer changes therefore no longer collapse into the final register state at
`take_pcm/1`. Instruction-internal DSP timing, RAM-write timestamps, the exact
32-cycle pipeline, and the synthesis features listed above remain approximate.

## Cartridge coprocessor inventory

[`cx4.ex`](lib/beamicom/snes/cx4.ex) now recognizes cartridge type `$F3` and
owns an 8 KiB host window at `$6000-$7FFF` in banks `$00-$3F/$80-$BF`.
[`bus.ex`](lib/beamicom/snes/bus.ex) routes CPU and DMA-visible reads/writes
through the cartridge coprocessor state before ordinary ROM/SRAM mapping.
Other chips remain missing and should converge on a common interface as their
timing and arbitration requirements become concrete.

### Priority chips for the supplied ROM set

| Chip | Command/instruction surface | Status |
|---|---|---|
| Capcom Cx4 | Command `$00` sprite functions; `$01` wireframe; `$05` propulsion; `$0D` vector length; `$10/$13` triangle; `$15` Pythagorean; `$1F` arctangent; `$22` trapezoid; `$25` multiply; `$2D` coordinate transform; `$40` sum; `$54` square; `$5C`, `$5E-$7E` immediate-register variants; `$89` immediate-ROM. Sixteen 24-bit registers live at `$7F80-$7FAF`; command at `$7F4F`; busy at `$7F5E`. | **Partial:** mapping, RAM mirroring, synchronous busy, ROM-to-RAM loads, command tracing, `$05/$15/$1F/$25/$40/$54/$5C/$89`. X3 passes its Cx4 self-test; graphics commands remain. |
| SuperFX GSU-1/2 | 256-byte instruction matrix with ALT1/ALT2/ALT3 variants. Families include STOP/NOP/CACHE; branches; TO/FROM/MOVE register transfers; WITH; ALT prefixes; STW/STB/LDW/LDB/SBK; LOOP/LINK/JMP/LJMP; PLOT/RPIX/COLOR/GETC; ADD/ADC/SUB/SBC/CMP; AND/BIC/OR/XOR; shifts/rotates; MULT/UMULT/LMULT/FMULT; MERGE; IBT/IWT; INC/DEC; GETB/GETBH/GETBL/GETBS; SEX/SWAP/NOT/LOB/HIB. Also requires GSU cache, ROM/RAM arbitration, register MMIO, IRQ, and timing. | Missing. Required by Star Fox and Yoshi's Island. |

### Remaining commercial enhancement chips

| Chip | Command/interface surface | Status |
|---|---|---|
| DSP-1/1A/1B | Commands: multiply `$00`, inverse `$10`, triangle `$04`, radius `$08`, range `$18` and `$38`, distance `$28`, rotate `$0C`, polar `$1C`, parameter `$02`, raster `$0A`, project `$06`, target `$0E`, attitude matrices A/B/C `$01/$11/$21`, objective transforms A/B/C `$0D/$1D/$2D`, subjective transforms A/B/C `$03/$13/$23`, scalar products A/B/C `$0B/$1B/$2B`, gyrate `$14`, memory test `$0F`, memory size `$2F`. | Missing. Needed by Super Mario Kart and Pilotwings, among others. |
| DSP-2 | `$01` bitmap-to-bitplane, `$03` transparent color, `$05` transparent overlay, `$06` reverse bitmap, `$09` 16x16 multiply, `$0D` scale bitmap, `$0F` reset/no-op. | Missing. |
| DSP-3 | Command processor for memory test/dump, coordinate conversion, pathfinding, and data decompression used by SD Gundam GX. Some variants require dumped firmware for low-level emulation. | Missing. |
| DSP-4 | Command processor for track projection, polygon/sprite transforms, clipping, and OAM generation used by Top Gear 3000. | Missing. |
| SA-1 | Second 65C816-derived CPU plus `$2200-$23FF` control/vector/IRQ, Super MMC ROM/BW-RAM mapping and protection, 2 KiB I-RAM, DMA and character conversion, arithmetic unit, timers/counters, bitmap mode, and variable-length bit processing. | Missing. |
| S-DD1 | ROM banking and streaming data decompression channels. | Missing. |
| SPC7110 / SPC7110+RTC | ROM mapping, data-decompression stream, math/data ports, and optional RTC-4513 interface. | Missing. |
| OBC-1 | Object attribute helper RAM and address/index register interface. | Missing. |
| S-RTC | Real-time-clock command/data protocol. | Missing. |
| ST010/ST011/ST018 | SETA command processors for vector/rotation/sort/math or game-specific AI; some variants require firmware. | Missing. |

Super Game Boy, BS-X/Satellaview, Nintendo Power flash, and modern MSU-1 are
separate platform/extension projects and are not part of the first commercial
cartridge-coprocessor wave.

## Concurrent implementation plan

Work should be split by subsystem ownership to minimize conflicts. Each lane
needs native golden tests before acceleration.

### Wave 0: shared cartridge boundary

One owner adds chip detection from map mode + cartridge type, a coprocessor
state field, CPU read/write dispatch, reset/step hooks, serialization-friendly
state, and mapper-specific ROM/RAM windows. This should land before Cx4 and
SuperFX branches so both use one interface rather than modifying `Bus` in
parallel.

### Wave 1: immediate compatibility and audio stability

| Lane | Scope | Primary verification |
|---|---|---|
| CPU | Explicit addressing carry/wrap policies and cycle tests. All opcodes, decimal ADC/SBC, TCS mode behavior, and WAI/BRK/COP paths were completed during this audit. | Processor conformance ROMs plus FFII/FFIII/SMW/Super Metroid |
| PPU | Modes 2/4/6 OPT; accurate VRAM ports; raster capture and DMA/HDMA timing fixes. Native mosaic and the principal OAM port/rotation behavior were completed during this audit. | Existing games plus targeted PPU test ROMs |
| APU | ADSR/GAIN, KON/KOFF release, and Gaussian interpolation. Persistent SPC cycle debt and DSP-register-event-ordered synthesis were completed during this audit. | Long FFIII/SMW playback plus audio golden tests |
| Cx4 | Shared interface consumer, registers/busy flag, command state machine, then commands in Mega Man X3 trace order | Mega Man X3 boot/gameplay and focused command vectors |

### Wave 2: enhanced-ROM coverage

| Lane | Scope |
|---|---|
| SuperFX core | GSU state, bus arbitration/cache, instruction matrix, register MMIO, timing, pixel cache |
| PPU completion | Hires/pseudo-hires/interlace, OBJ limits/rotation/sizes, status/counters/open bus |
| S-DSP completion | PMON/noise, echo RAM, EFB/EVOL/EON/ESA/EDL, FIR and pipeline timing |
| DSP-1 | Command protocol and fixed-point math, starting with Super Mario Kart traces |

SA-1, S-DD1, SPC7110, OBC-1, S-RTC, DSP-2/3/4, and SETA chips follow based on
ROM priority. Firmware-dependent implementations must not embed copyrighted
firmware; accept user-supplied dumps or use a verified high-level command model.

## Performance hotspots and Nx suitability

Correctness comes first: an accelerated path should be compared against a
native golden implementation and must preserve integer/fixed-point behavior.

### Strong Nx candidates

1. **Frame-wide PPU composition.** Generalize the existing fused Mode 1/7
   kernels to modes 0 and 2-6, 8bpp, offset-per-tile, mosaic, windows, color
   math, 512-wide hires, and interlaced output. Tile gather, coordinate
   transforms, masks, priorities, and palette lookup are naturally tensorized.
2. **OBJ rasterization.** Native rendering builds maps and loops through
   sprites/pixels per row. A frame-wide OAM+VRAM tensor kernel can enforce the
   32-OBJ/34-sliver limits and fuse OBJ priority/color math with backgrounds.
3. **Block S-DSP mixing after timeline correctness.** Batch eight voices over
   a useful PCM block: Gaussian interpolation, envelope and volume multiply,
   pitch modulation/noise, stereo reduction, echo FIR, clamp, and PCM packing.
4. **Cx4 batch math, selectively.** Coordinate transforms, wireframe point
   transforms, and sprite-command arrays can use cached fixed-shape kernels if
   profiling proves command batches are large enough. Small scalar commands
   should stay native.
5. **DSP-1 matrix/raster batches, selectively.** Repeated raster/coordinate
   transforms are plausible cached kernels, but exact fixed-point golden tests
   and command-size profiling are required first.

### Native optimizations before or alongside Nx

- Avoid converting the full 64 KiB VRAM and 544-byte OAM arrays every rendered
  frame. Use binary-backed storage or dirty-page updates; the Nx path likewise
  should update only dirty tensor pages.
- Eliminate per-frame task creation, per-row flattened tile lists, per-pixel
  recursive layer selection, and repeated transient maps in the native PPU.
- Render DSP samples into larger iodata/binary blocks rather than appending a
  stereo binary per sample; cache/predecode BRR blocks where writes permit.
- Reduce persistent `:array` accesses in SPC/CPU/bus hot loops with storage and
  dispatch representations chosen for BEAM update/read patterns.
- SuperFX instruction dispatch, CPU/SPC execution, MMIO, DMA/HDMA scheduling,
  timers, interrupt logic, and decompression bitstreams are branchy/sequential
  state machines. They are poor Nx targets; optimize them natively.

The current Nx renderer is intentionally narrow: 224-line Mode 1 with 8x8
tiles, or Mode 7, with constant palette and restricted window state. Native
fallback is therefore common as compatibility expands. Warm compiled kernels,
cache them by shape/variant, and measure end-to-end frame plus audio throughput;
do not count compilation in steady-state benchmarks.

On the audit machine, the same FFIII window after 1,700 warm-up frames measured
69.92 FPS native and 80.40 FPS with Nx over 120 frames. Both paths produced the
same final RGB CRC32; 46 frames were rendered and 74 reused. This is a useful
directional result, not a portable performance guarantee: hardware, runtime,
scene, render/reuse ratio, and compiled-kernel cache state all matter.

The changing SMW title window after 300 warm-up frames is a stricter case with
no frame reuse. Over 120 frames it measured 59.11 FPS native and 82.14 FPS with
Nx, with identical final RGB CRC32 and active PCM. Its dominant native CPU
hotspot was a direct-page NMI polling loop; the interpreter now recognizes that
stable loop shape and batches iterations only up to the next scanline boundary.

## References

- [WDC W65C816S data sheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
- [Nintendo SNES Development Manual, Book I](https://floating.muncher.se/bot/manual/book1_text.pdf)
- [Nintendo SNES Development Manual, Book II](https://floating.muncher.se/bot/manual/book2_text.pdf)
- [SPC700 instruction set](https://snes.nesdev.org/wiki/SPC-700_instruction_set)
- [S-DSP registers](https://snes.nesdev.org/wiki/S-DSP_registers)
- [PPU registers](https://snes.nesdev.org/wiki/PPU_registers)
- [SuperFX opcode matrix](https://wiki.superfamicom.org/super-fx-opcode-matrix)
- [Cx4 command/register documentation](https://wiki.superfamicom.org/capcom-cx4-hitachi-hg51b169)
- [DSP-1 command documentation](https://snes.nesdev.org/wiki/DSP-1)
- [DSP enhancement-chip overview](https://snes.nesdev.org/wiki/DSP_Expansion)
- [Snes9x DSP-2 command implementation](https://github.com/snes9xgit/snes9x/blob/master/dsp2.cpp)
- [bsnes reference implementation](https://github.com/bsnes-emu/bsnes)
