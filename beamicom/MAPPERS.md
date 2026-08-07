# Mapper compatibility

Beamicom currently implements 16 iNES/NES 2.0 mapper numbers. A mapper being
listed here means its register decoding and primary banking behavior are
implemented; it does not guarantee that every cartridge board, hardware quirk,
or homebrew use of that mapper is cycle-perfect.

## Supported mappers

| Mapper | Hardware | Implemented behavior |
| ---: | --- | --- |
| 0 | NROM | Fixed 16KB/32KB PRG ROM and CHR ROM/RAM |
| 1 | MMC1 | Serial registers, PRG/CHR banking, mirroring, PRG RAM banking and protection, large-ROM outer banking, and fixed-32KB NES 2.0 submapper 5 boards |
| 2 | UxROM | Switchable 16KB PRG bank and fixed final bank; NES 2.0 bus-conflict metadata |
| 3 | CNROM | Switchable 8KB CHR bank; NES 2.0 bus-conflict metadata |
| 4 | MMC3/MMC6 | PRG/CHR banking, mirroring, scanline IRQs, MMC3 PRG RAM protection, and NES 2.0 submapper 1 MMC6 RAM controls |
| 5 | MMC5 | PRG/CHR modes, PRG RAM and protection, ExRAM and nametable routing, extended attributes, fill mode, vertical split, multiplier, scanline IRQ, and expansion audio |
| 7 | AxROM | Switchable 32KB PRG bank, single-screen mirroring, and submapper-specific bus conflicts |
| 9 | MMC2 | Switchable PRG and latch-controlled CHR banks |
| 10 | MMC4 | Switchable PRG and latch-controlled CHR banks |
| 11 | Color Dreams | Combined PRG/CHR bank register and bus conflicts |
| 34 | BNROM | Switchable 32KB PRG bank and bus conflicts |
| 66 | GxROM | Combined PRG/CHR bank register and bus conflicts |
| 69 | Sunsoft FME-7 | PRG/CHR banking, banked PRG RAM/ROM window, mirroring, CPU-cycle IRQ, and Sunsoft 5B audio |
| 118 | TxSROM | MMC3 banking and IRQs with CHR-controlled per-nametable CIRAM selection |
| 119 | TQROM | MMC3 banking and IRQs with simultaneous, per-bank CHR ROM/RAM selection |
| 206 | DxROM / Namco 108 | Two switchable 8KB PRG banks, fixed final 16KB PRG, and MMC3-style 2KB/1KB CHR banking without IRQs |

The emulator parses NES 2.0 mapper, submapper, ROM-size, and RAM-size metadata.
Only the board variants described above receive specialized submapper behavior.
For example, MMC1 submapper 6's serial EEPROM is not implemented.

Mapper 34 is implemented as BNROM. The unrelated NINA-001 hardware that shares
the historical mapper-34 number is not yet supported.

## Unsupported mappers

Every mapper number not present in the supported table is unsupported. In
numeric terms, that is:

- Mapper 6
- Mapper 8
- Mappers 12–33
- Mappers 35–65
- Mappers 67–68
- Mappers 70–117
- Mappers 120–205
- Mappers 207–4095

This includes common unsupported families such as Famicom Disk System, VRC1–7,
Namco 163, Bandai FCG, Sunsoft-4, RAMBO-1, and other MMC3-derived boards.
An unsupported mapper may appear to boot because the fallback memory layout is
NROM-like, but bank switching and mapper IRQs will not work correctly.

When adding a mapper, update both this document and the implementation list in
`Beamicom.NES.Mapper`, and add banking and IRQ tests using a synthetic cartridge.
