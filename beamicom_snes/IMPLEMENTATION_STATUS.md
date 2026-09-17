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
| PPU modes | Native paths for modes 0-7, including OPT and Mode 5/6 hires fetch | Native 512-wide output, field weaving, OBJ edge cases |
| SPC700 | **256/256 opcode bytes**, lightly validated | Exact instruction/MMIO timing and conformance tests; fragmented-cycle debt is handled |
| S-SMP | Ports, native IPL execution, timers, MMIO opcode fetch, timed DSP/RAM visibility, distinct SLEEP/STOP | TEST speed-control wait states, CPU/APU port collision tie ordering, broader instruction bus-sequence validation |
| S-DSP | Single clocked eight-voice BRR pipeline with ADSR/GAIN, Gaussian interpolation, PMON/noise, echo/FIR, and live ENVX/OUTX/ENDX state | Further reference-emulator validation of exact per-phase collision behavior |
| Cartridge coprocessors | **Partial Cx4, SuperFX, DSP-1, and SA-1** | Remaining chip commands, cycle-level arbitration, DSP-1 busy timing/ROM dump, and the SA-1 CPU/DMA scheduler |
| Nx/EXLA | Optimized subsets of Mode 1 and Mode 7; the APU renderer option currently preserves the authoritative native phase pipeline | Broader fused PPU kernels; port DSP spans only after full state/RAM parity is proven |

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
- Absolute indexed and indirect indexed addressing now preserves 24-bit bank
  carry; further conformance cases remain to be validated.
- Emulation-mode direct-page indexed-pointer wrapping is implemented; the
  remaining unusual stack/push wrapping cases still need conformance coverage.
- Direct-page, page-cross, indexed-store, and 16-bit-index cycle penalties are
  incomplete.
- Sixteen-bit data reads/writes carry across the 24-bit address, while pointer
  fetches retain bank-local wrapping; more addressing-mode boundary tests remain.
- TCS preserves stack page `$01` in emulation mode and transfers all 16 bits in
  native mode.

NMI has priority over IRQ, IRQ masking works, native/emulation and BRK/COP
vectors are selected, WAI wakes for masked IRQ and vectors for accepted
interrupts, and RTI restores the appropriate state. STP is explicit and only a
reset may restart it. Remaining gaps include ABORT, runtime reset sequencing,
and IRQ polling-delay quirks around CLI/SEI/PLP/RTI.

## PPU register inventory

Unhandled PPU writes fall through unchanged at
[`ppu.ex:493`](lib/beamicom/snes/ppu.ex#L493); unhandled reads return open-bus
data at [`ppu.ex:579`](lib/beamicom/snes/ppu.ex#L579).

| Register | Status | Implemented behavior and gaps |
|---|---|---|
| `$2100` INIDISP | Implemented | Forced blank and brightness work, including mid-scanline output-state transitions. Register-specific pixel-pipeline propagation delays remain approximate. |
| `$2101` OBSEL | Implemented | Base/name selection, palette, priority, flips, all square size pairs, and rectangular size modes 6/7 work. |
| `$2102-$2104` OAMADD/OAMDATA | Partial | Word addressing, low-table write latch/pair commit, high-table mirroring, vblank reset, and internal-address priority rotation work. Active-display writes are suppressed instead of redirected to the exact live fetch address. |
| `$2105` BGMODE | Partial | Mode and priority tables exist for modes 0-7; mode-specific gaps are listed below. |
| `$2106` MOSAIC | Implemented | Native 1x1 through 16x16 sampling, vertical phase reload, independent BG enables, scanline-state persistence, and Mode 7 EXTBG split-axis behavior. Mid-scanline reload begins at the next represented scanline. Active mosaic selects native fallback. |
| `$2107-$210A` BGnSC | Implemented | Basic tilemap bases and sizes. |
| `$210B-$210C` BGnNBA | Implemented | Basic character-data bases. |
| `$210D-$2114` BGnHOFS/BGnVOFS | Implemented | Shared scroll-latch behavior, Mode 7 latch, Modes 2/4/6 offset-per-tile, and mid-scanline output-state transitions work. Fetch lookahead and register-specific propagation delays remain approximate. |
| `$2115-$2119` VMAIN/VMADD/VMDATA | Implemented | Increment/remap, VRAM read buffering/prefetch, and display-period access restrictions work. |
| `$211A-$2120` M7SEL/matrix/center | Implemented | Matrix writes, multiply result, affine flips/repeat/fill, tile-zero fill, and mid-scanline output-state transitions work. |
| `$2121-$2122` CGADD/CGDATA | Partial | 15-bit palette access, shared byte phase, retained write latch, and access windows work. Active-display writes are suppressed instead of redirected to the exact live fetch address. |
| `$2123-$212B` windows | Implemented | Layer selection, positions, and OR/AND/XOR/XNOR combination. |
| `$212C-$212F` screen designation | Implemented | Main/sub screen and their window masks. |
| `$2130-$2132` color math | Implemented | Add/subtract, correct add-half ordering, fixed color, subscreen fallback, direct color, OBJ palette gating, windows, and mid-scanline transitions work. |
| `$2133` SETINI | Partial | Screen/OBJ interlace, overscan, pseudo-hires, and EXTBG are stored. OBJ and Mode 5/6 addressing select field-aware rows. Pseudo-hires is downsampled by averaging each sub/main pair into the compatible 256-wide frame; true 512-wide and field-woven output and external sync remain absent. |
| `$2134-$2136` MPY | Implemented | Mode 7 multiplication result. |
| `$2137` SLHV | Implemented | Software H/V latch honors WRIO bit 7; `$4201` high-to-low transitions also latch the counters. |
| `$2138` OAMDATAREAD | Partial | Reads, mirroring, increments, MDR behavior, and priority-rotation updates work. Active-display reads return open bus instead of the exact live fetch byte. |
| `$2139-$213A` VMDATAREAD | Implemented | Required prefetch/read-buffer, increment, access-window, and PPU1 MDR behavior work. |
| `$213B` CGDATAREAD | Partial | Shared byte phase, address increment, retained write latch, and PPU2 MDR bit 7 work. Active-display reads return open bus instead of the exact live fetch byte. |
| `$213C-$213D` OPHCT/OPVCT | Implemented | Independent two-phase 9-bit counter reads preserve PPU2 MDR high bits and reset through `$213F`. |
| `$213E-$213F` STAT77/STAT78 | Partial | PPU versions, distinct PPU1/PPU2 MDR behavior, OBJ range/time-over flags, field, region, and counter-latch state are implemented. Overflow timing is scanline-granular and rendering does not yet truncate after the 34th OBJ sliver. |

### Rendering modes and related features

| Feature | Status |
|---|---|
| Mode 0 | Native four-layer 2bpp rendering, priorities, and palette partition implemented. |
| Mode 1 | Native implemented, including BG3 priority. Nx supports a restricted 8x8-tile path. |
| Mode 2 | Native 4bpp layers with BG3 horizontal/vertical offset-per-tile. |
| Mode 3 | Native 8bpp BG1 + 4bpp BG2 and direct color implemented. |
| Mode 4 | Native bit depths, priorities, direct color, and BG3 direction-selected offset-per-tile. |
| Mode 5 | Native 512-pixel background fetch and 16x8/16x16 tile semantics; output is downsampled to the public 256-wide frame. Vertical interlace is field-selective rather than field-woven. |
| Mode 6 | Native 512-pixel BG1 fetch, priorities, and BG3 offset-per-tile; output is downsampled to 256 pixels. |
| Mode 7 | Native and Nx affine rendering, direct color, repeat/fill/flips, EXTBG priorities, and mid-scanline output-state transitions implemented. |
| BG tiles | 2/4/8bpp decode, 8x8/16x16 groups, and tilemap sizes implemented. |
| OBJ | 128 entries, 32 sprites/line, 4bpp palettes, flips, priorities, name selection, rectangular sizes, priority rotation, field-aware OBJ interlace, and range/time-over flags. Rendering does not yet suppress slivers after the 34th fetched sliver. |
| Windows/color math | Broadly implemented with the accuracy gaps above. |
| Mosaic | Native implementation for modes 0-7; active mosaic currently falls back from Nx. |
| Hires/pseudo-hires/interlaced pixels | Partial. Mode 5/6 use 512-pixel background addressing and even/odd sub/main samples, then average each pair into the public 256-wide frame. Pseudo-hires uses the same pair representation. OBJ and Mode 5/6 choose field-aware source rows. Native 512-wide and field-woven frame APIs are missing. |

Timing includes NTSC/PAL scanline lengths, NTSC short and PAL long lines,
vblank selection, NMI, H/V IRQs, dot-positioned CPU-written raster segments,
display-period PPU access windows, and B-to-A PPU read side effects. Missing or
approximate pieces include the 40-master-clock DRAM refresh stall, exact live
OAM/CGRAM fetch-address redirection, tile-fetch lookahead, register-specific
pixel-pipeline delays, DMA byte-level timing, HDMA clocks/stalls, and
overscan-aware HDMA.

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
[`spc700.ex:80`](lib/beamicom/snes/spc700.ex#L80). Common load, store, ALU,
read-modify-write, stack, and word operations now position their bus effects
within the instruction so DSP writes and timer/MMIO reads carry a meaningful
access-cycle timestamp. Opcode fetch uses the MMIO-aware path, while SLEEP and
STOP retain distinct halt/wake state. Other instruction bus sequences still
need auditing, and the test suite is not exhaustive.

### SPC fragmented-cycle accounting

This audit found that an earlier `SPC700.run/2` discarded instruction overshoot,
allowing repeated tiny `$2140-$2143` port flushes to overclock the SPC. The
current implementation stores a signed `cycle_credit`: a complete instruction
may create negative debt, and later grants pay it down before another opcode
executes. Fragmented-versus-batched SPC and APU tests now cover this behavior.

### S-SMP registers

| Register | Status | Notes |
|---|---|---|
| `$F0` TEST | Partial | RAM-write and timer/test gates are implemented. Address-sensitive CPU wait-state and separate timer speed scaling remain deferred. |
| `$F1` CONTROL | Partial | Timer enables, input-port clear, and IPL visibility exist; enable resets stage two/output while preserving the free-running divider phase. Exact write-edge behavior remains lightly validated. |
| `$F2` DSPADDR | Implemented | Address latch. |
| `$F3` DSPDATA | Implemented boundary | Reads mask bit 7, writes ignore `$80-$FF`, and access-time reads see phase-current DSP state. |
| `$F4-$F7` CPUIO | Partial | Directional latches and clear controls work; same-cycle collision behavior absent. |
| `$F8-$F9` AUX | Implemented | Auxiliary RAM values. |
| `$FA-$FC` timer targets | Implemented boundary | Zero-as-256 and write-only read behavior are covered; TEST speed scaling remains deferred. |
| `$FD-$FF` timer outputs | Partial | Four-bit wrap, clear-on-read, divider phase, and enable edges are covered; TEST speed scaling remains deferred. |
| `$FFC0-$FFFF` IPL overlay | Implemented | Normal boot executes the 64-byte IPL, including CPU-port upload and indirect launch; focused tests cover a complete native transfer. |

### S-DSP registers and synthesis

Per-voice register groups `$x0-$x9` apply to voices 0-7.

| Register/feature | Status |
|---|---|
| `VOLL/VOLR $x0/$x1` | Implemented |
| `PITCHL/PITCHH $x2/$x3` | Implemented with Gaussian interpolation and PMON |
| `SRCN $x4`, `DIR $5D` | Implemented |
| BRR decode, filters 0-3, end/loop | Implemented with phase-tracked fetch/decode state |
| `ADSR1/ADSR2 $x5/$x6` | Implemented |
| `GAIN $x7`, all gain modes | Implemented |
| `ENVX $x8`, `OUTX $x9` | Live phase-updated reads implemented |
| `MVOLL/MVOLR $0C/$1C` | Implemented |
| `EVOLL/EVOLR $2C/$3C` | Implemented |
| `KON $4C` | Phase-polled latch and five-sample start delay implemented |
| `KOFF $5C` | Phase-polled release behavior implemented |
| `FLG $6C` | Mute, reset, noise rate, and echo-write disable implemented |
| `ENDX $7C` | Live phase-updated end/loop flags and clear behavior implemented |
| `EFB $0D` | Implemented |
| `PMON $2D` | Implemented for voices 1-7 |
| `NON $3D` | Implemented with persistent clocked LFSR |
| `EON $4D` | Implemented |
| `ESA $6D`, `EDL $7D` | Implemented with wrapping echo ring |
| FIR coefficients `$0F-$7F` | Eight taps implemented |
| Gaussian interpolation | Implemented |
| Echo RAM writes and eight-tap FIR | Phase-timed reads/writes implemented against shared SPC RAM |
| Exact 32-cycle DSP pipeline | Explicit phase clock and live voice/register state implemented; further collision conformance remains |

`APU.advance/3` synchronizes SPC bus accesses with a phase-current DSP/RAM
shadow, then commits authoritative PCM and state once through the phase
pipeline. DSPDATA reads see live register state and SPC RAM reads
see earlier echo writes even across an overdrawn instruction. Remaining known
timing gaps are TEST wait-state scaling, CPU/APU port collision tie ordering,
and broader external conformance coverage.

The shared 64 KiB APU RAM is atomics-backed at runtime. Overdrawn SPC
instructions use a short-lived write overlay for future-clock reads and writes,
then discard it at the exact batch boundary; they do not copy the complete RAM.
Runtime snapshots clone the atomics buffer, while save-state version 2 stores it
as a byte-exact binary and restores a fresh atomics allocation.

## Cartridge coprocessor inventory

[`bus.ex`](lib/beamicom/snes/bus.ex) routes CPU and DMA-visible reads/writes
through cartridge-specific Cx4, SuperFX, DSP-1, and SA-1 state before ordinary
ROM/SRAM mapping. SuperFX RAM/cache use per-machine mutable storage so GSU
pixel workloads do not rebuild persistent trees for every byte. Coprocessors
still execute synchronously while their cycle-level schedulers and arbitration
rules are developed.

### Priority chips for the supplied ROM set

| Chip | Command/instruction surface | Status |
|---|---|---|
| Capcom Cx4 | Command `$00` sprite functions; `$01` wireframe; `$05` propulsion; `$0D` vector length; `$10/$13` polar conversion; `$15` Pythagorean; `$1F` arctangent; `$22` trapezoid; `$25` multiply; `$2D` coordinate transform; `$40` sum; `$54` square; `$5C`, `$5E-$7E` immediate-register variants; `$89` immediate-ROM. Sixteen 24-bit registers live at `$7F80-$7FAF`; command at `$7F4F`; busy at `$7F5E`. | **Partial:** mapping, RAM mirroring, synchronous busy, ROM-to-RAM loads, command tracing, `$00` composite OAM build plus scale/rotate modes `$03/$07`, and `$05/$0D/$10/$13/$15/$1F/$22/$25/$2D/$40/$54/$5C/$89`. X3 passes its Cx4 self-test and renders composite boss sprites in its attract sequence; transform-lines, wireframe, disintegration, and wave commands remain. |
| SuperFX GSU-1/2 | 256-byte instruction matrix with ALT1/ALT2/ALT3 variants. Families include STOP/NOP/CACHE; branches; TO/FROM/MOVE register transfers; WITH; ALT prefixes; STW/STB/LDW/LDB/SBK; LOOP/LINK/JMP/LJMP; PLOT/RPIX/COLOR/GETC; ADD/ADC/SUB/SBC/CMP; AND/BIC/OR/XOR; shifts/rotates; MULT/UMULT/LMULT/FMULT; MERGE; IBT/IWT; INC/DEC; GETB/GETBH/GETBL/GETBS; SEX/SWAP/NOT/LOB/HIB. Also requires GSU cache, ROM/RAM arbitration, register MMIO, IRQ, and timing. | **Partial:** complete native opcode-family decode, GSU register/cache/ROM/RAM state, S-CPU mapping, IRQ/STOP jobs, and PLOT/RPIX bitplanes. Yoshi's Island reaches recognizable GSU-rendered intro graphics. Jobs are still atomic rather than cycle-interleaved, and active workload throughput remains below 60 FPS. |

### Remaining commercial enhancement chips

| Chip | Command/interface surface | Status |
|---|---|---|
| DSP-1/1A/1B | Commands: multiply `$00`, inverse `$10`, triangle `$04`, radius `$08`, range `$18` and `$38`, distance `$28`, rotate `$0C`, polar `$1C`, parameter `$02`, raster `$0A`, project `$06`, target `$0E`, attitude matrices A/B/C `$01/$11/$21`, objective transforms A/B/C `$0D/$1D/$2D`, subjective transforms A/B/C `$03/$13/$23`, scalar products A/B/C `$0B/$1B/$2B`, gyrate `$14`, memory test `$0F`, memory size `$2F`. | **Partial:** all listed high-level command families and aliases dispatch; projection uses firmware-style fixed-point normalization, interpolation, clipping, and truncation; matrices retain state; Raster streams successive Mode 7 matrices and honors write-to-terminate behavior. Super Mario Kart reaches a race with clean command framing. ROM dump `$1F`, command busy timing, and DSP-1B revision differences remain. |
| DSP-2 | `$01` bitmap-to-bitplane, `$03` transparent color, `$05` transparent overlay, `$06` reverse bitmap, `$09` 16x16 multiply, `$0D` scale bitmap, `$0F` reset/no-op. | Missing. |
| DSP-3 | Command processor for memory test/dump, coordinate conversion, pathfinding, and data decompression used by SD Gundam GX. Some variants require dumped firmware for low-level emulation. | Missing. |
| DSP-4 | Command processor for track projection, polygon/sprite transforms, clipping, and OAM generation used by Top Gear 3000. | Missing. |
| SA-1 | Second 65C816-derived CPU plus `$2200-$23FF` control/vector/IRQ, Super MMC ROM/BW-RAM mapping and protection, 2 KiB I-RAM, DMA and character conversion, arithmetic unit, timers/counters, bitmap mode, and variable-length bit processing. | **Foundation:** chip detection, S-CPU MMIO/IRQ/vector handshake, Super MMC ROM banks, protected I-RAM/BW-RAM windows, and signed multiply/unsigned divide/40-bit accumulation. The second 65C816 scheduler, DMA/character conversion, timers, bitmap access, and variable-bit reader remain. |
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
| S-DSP conformance | Reference-emulator collision traces, installed Blargg fixtures, and real-game audio captures |
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
- Reduce persistent `:array` accesses in CPU/bus hot loops with storage and
  dispatch representations chosen for BEAM update/read patterns. SPC/APU RAM
  now uses machine-owned atomics with explicit snapshot boundaries.
- SuperFX instruction dispatch, CPU/SPC execution, MMIO, DMA/HDMA scheduling,
  timers, interrupt logic, and decompression bitstreams are branchy/sequential
  state machines. They are poor Nx targets; optimize them natively.

The current Nx renderer is intentionally narrow: 224-line Mode 1 with 8x8
tiles, or Mode 7, with constant palette and restricted window state. Native
fallback is therefore common as compatibility expands. Warm compiled kernels,
cache them by shape/variant, and measure end-to-end frame plus audio throughput;
do not count compilation in steady-state benchmarks.

After the register-accuracy pass, profiling showed that OBJ overflow accounting
was repeatedly decoding all 128 OAM entries on every visible line. The PPU now
builds and caches per-line sprite/sliver limits for each OAM state, retaining
mid-frame invalidation. The later phase-accurate S-DSP pipeline made older
80-87 FPS PPU-focused measurements incomparable with the current full-system
workload.

The event-aware audio path now advances SPC700 and S-DSP state in one pass. It
synchronizes only at DSP-visible RAM/register barriers, retains the bounded tail
of an instruction that crosses a scheduling grant, and applies carried writes
as their individual clocks become due. This removed the former full DSP replay
while preserving the replay implementation as a test oracle. The PPU render
pipeline also reuses an owner-local worker so its process-local decoded-tile and
compiled-render caches survive across frames. The retired block synthesizer is
no longer a second source of voice state. Event-free aligned samples flatten
the authoritative voice operations and collapse only live-register publications
that cannot be observed inside the aligned span. Interrupted samples and
echo/BRR overlaps retain their exact phase boundaries. BRR dependency fences use
compact contiguous regions while retaining PMON's maximum traversal and both
live and latched directory pointers.

On the development host, controlled 180-frame windows measured 52.30 FPS native
and 54.23 FPS Nx-selected for SMW after 300 warm-up frames, 45.14/46.61 FPS for
FFIII after 600, and 37.29/37.27 FPS for Super Metroid after 600. All runs had
active PCM, no SPC error, and rendered every frame. Each native/Nx pair produced
identical video, audio, and canonical hardware-state SHA-256 hashes. The
benchmark now also reports p50/p95/max latency and offers `--profile` for opt-in
BEAM call instrumentation. The 60 FPS target therefore remains open. These
figures remain directional rather than portable.

## References

- [WDC W65C816S data sheet](https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf)
- [Nintendo SNES Development Manual, Book I](https://floating.muncher.se/bot/manual/book1_text.pdf)
- [Nintendo SNES Development Manual, Book II](https://floating.muncher.se/bot/manual/book2_text.pdf)
- [SPC700 instruction set](https://snes.nesdev.org/wiki/SPC-700_instruction_set)
- [S-DSP registers](https://snes.nesdev.org/wiki/S-DSP_registers)
- [PPU registers](https://snes.nesdev.org/wiki/PPU_registers)
- [SuperFX opcode matrix](https://wiki.superfamicom.org/super-fx-opcode-matrix)
- [SuperFX flag clobber table](https://wiki.superfamicom.org/super-fx-flag-clobber-table)
- [Cx4 command/register documentation](https://wiki.superfamicom.org/capcom-cx4-hitachi-hg51b169)
- [DSP-1 command documentation](https://snes.nesdev.org/wiki/DSP-1)
- [DSP enhancement-chip overview](https://snes.nesdev.org/wiki/DSP_Expansion)
- [Snes9x DSP-2 command implementation](https://github.com/snes9xgit/snes9x/blob/master/dsp2.cpp)
- [bsnes reference implementation](https://github.com/bsnes-emu/bsnes)
