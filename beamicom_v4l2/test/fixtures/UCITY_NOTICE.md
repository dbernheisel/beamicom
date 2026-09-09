# µCity compatibility test ROM

`ucity_compat_v1.3.gbc` is an unmodified copy of the official compatibility
build of µCity 1.3 for Game Boy Color. It is included as an interoperability
test fixture together with its tagged Corresponding Source and GPL text.

- Author: AntonioND/SkyLyrac (Antonio Niño Díaz)
- Project source: https://codeberg.org/SkyLyrac/ucity
- Official release: https://codeberg.org/SkyLyrac/ucity/releases/tag/v1.3
- Tagged source: https://codeberg.org/SkyLyrac/ucity/src/tag/v1.3
- Original release asset: https://codeberg.org/SkyLyrac/ucity/releases/download/v1.3/ucity_compat.gbc
- Official source archive: https://codeberg.org/SkyLyrac/ucity/archive/v1.3.tar.gz

Included files:

- `ucity_compat_v1.3.gbc`: 131,072 bytes; SHA-256
  `8b98cbb5303d2159a931332dc375642fb474b2c9473c7ba473ad94c98a8814bf`
- `ucity-v1.3-source.tar.gz`: 1,029,082 bytes; SHA-256
  `75a2605a4e7d7bee4a6bacbdd608b161868fd3e70074406ffbc65688f6c70724`
- `gpl-3.0.txt`: the GPLv3 text from the tagged source archive

To rebuild after extracting `ucity-v1.3-source.tar.gz`, install a recent RGBDS
toolchain (`rgbasm`, `rgblink`, and `rgbfix`) and run `make` in the extracted
`ucity` directory. The Makefile builds both `ucity.gbc` and
`ucity_compat.gbc`; set its `RGBDS` variable if the tools are not on the normal
executable path.

The upstream project describes the game as GPLv3 or later, with some source
components under their own per-file licenses and media under CC BY-SA 4.0. See
the headers and license notices within the included source archive for the
third-party component terms.

This notice is attribution for the upstream fixture and does not alter its
license terms.
