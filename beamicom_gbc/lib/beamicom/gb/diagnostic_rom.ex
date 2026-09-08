defmodule Beamicom.GB.DiagnosticROM do
  @moduledoc """
  Builds a self-authored ROM-only diagnostic cartridge for visual bring-up.

  The DMG and CGB ROMs execute SM83 programs which disable the LCD and populate
  video hardware through CPU-visible registers. The CGB program additionally
  writes both VRAM banks, tile attributes, BG/OBJ color RAM, and starts OAM DMA.
  No framebuffer or PPU internals are preloaded by the generator.
  """

  import Bitwise

  @rom_size 0x8000
  @entry 0x0150
  @copy 0x01D0
  @tiles 0x0300
  @background 0x0400
  @window 0x0800
  @oam 0x0C00

  @cgb_entry 0x0150
  @cgb_copy 0x0280
  @cgb_palette_copy 0x0290
  @cgb_tiles0 0x0300
  @cgb_tiles1 0x0400
  @cgb_background 0x0800
  @cgb_window 0x0C00
  @cgb_bg_attrs 0x1000
  @cgb_window_attrs 0x1400
  @cgb_oam 0x1800
  @cgb_bg_palette 0x1900
  @cgb_obj_palette 0x1940

  @doc "Returns the complete, checksummed 32 KiB diagnostic ROM image."
  @spec build() :: binary()
  def build do
    tiles = tile_data()
    background = tilemap(:background)
    window = tilemap(:window)
    oam = oam_data()

    :binary.copy(<<0>>, @rom_size)
    |> put_bytes(0x0100, <<0xC3, @entry::little-16, 0>>)
    |> put_bytes(0x0134, "BEAM DIAG" <> :binary.copy(<<0>>, 7))
    |> put_byte(0x0143, 0x00)
    |> put_byte(0x0147, 0x00)
    |> put_byte(0x0148, 0x00)
    |> put_byte(0x0149, 0x00)
    |> put_bytes(@entry, program(byte_size(tiles), byte_size(oam)))
    |> put_bytes(@copy, copy_routine())
    |> put_bytes(@tiles, tiles)
    |> put_bytes(@background, background)
    |> put_bytes(@window, window)
    |> put_bytes(@oam, oam)
    |> with_header_checksum()
  end

  @doc "Returns a checksummed CGB-only diagnostic ROM executed entirely by the CPU."
  @spec build_cgb() :: binary()
  def build_cgb do
    tiles0 = tile_data()
    tiles1 = cgb_tile_data()
    background = tilemap(:background)
    window = tilemap(:window)
    bg_attrs = cgb_tilemap_attributes(:background)
    window_attrs = cgb_tilemap_attributes(:window)

    :binary.copy(<<0>>, @rom_size)
    |> put_bytes(0x0100, <<0xC3, @cgb_entry::little-16, 0>>)
    |> put_bytes(0x0134, "BEAM CGB DIAG" <> :binary.copy(<<0>>, 2))
    |> put_byte(0x0143, 0xC0)
    |> put_byte(0x0147, 0x00)
    |> put_byte(0x0148, 0x00)
    |> put_byte(0x0149, 0x00)
    |> put_bytes(@cgb_entry, cgb_program(byte_size(tiles0), byte_size(tiles1)))
    |> put_bytes(@cgb_copy, copy_routine())
    |> put_bytes(@cgb_palette_copy, palette_copy_routine())
    |> put_bytes(@cgb_tiles0, tiles0)
    |> put_bytes(@cgb_tiles1, tiles1)
    |> put_bytes(@cgb_background, background)
    |> put_bytes(@cgb_window, window)
    |> put_bytes(@cgb_bg_attrs, bg_attrs)
    |> put_bytes(@cgb_window_attrs, window_attrs)
    |> put_bytes(@cgb_oam, cgb_oam_data())
    |> put_bytes(@cgb_bg_palette, cgb_bg_palette())
    |> put_bytes(@cgb_obj_palette, cgb_obj_palette())
    |> with_header_checksum()
  end

  defp program(tile_bytes, oam_bytes) do
    IO.iodata_to_binary([
      # Disable interrupts and the LCD while writing VRAM/OAM.
      <<0xF3, 0x31, 0xFE, 0xFF, 0x3E, 0x00, 0xE0, 0x40>>,
      # Identity background/object palettes, scroll origin, and window at x=80.
      ldh(0x47, 0xE4),
      ldh(0x48, 0xE4),
      ldh(0x49, 0x1B),
      ldh(0x42, 0),
      ldh(0x43, 0),
      ldh(0x4A, 0),
      ldh(0x4B, 87),
      copy(@tiles, 0x8000, tile_bytes),
      copy(@background, 0x9800, 0x0400),
      copy(@window, 0x9C00, 0x0400),
      copy(@oam, 0xFE00, oam_bytes),
      # LCD on: window/map 9C00, unsigned tiles, sprites, and background.
      ldh(0x40, 0xF3),
      # Stable terminal loop.
      <<0x18, 0xFE>>
    ])
  end

  defp cgb_program(tiles0_bytes, tiles1_bytes) do
    IO.iodata_to_binary([
      # DI; initialize stack; disable LCD before writing either VRAM bank.
      <<0xF3, 0x31, 0xFE, 0xFF, 0x3E, 0x00, 0xE0, 0x40>>,
      cgb_copy(@cgb_tiles0, 0x8000, tiles0_bytes),
      cgb_copy(@cgb_background, 0x9800, 0x0400),
      cgb_copy(@cgb_window, 0x9C00, 0x0400),
      # Bank 1 holds alternate graphics and attributes for both tile maps.
      ldh(0x4F, 1),
      cgb_copy(@cgb_tiles1, 0x8000, tiles1_bytes),
      cgb_copy(@cgb_bg_attrs, 0x9800, 0x0400),
      cgb_copy(@cgb_window_attrs, 0x9C00, 0x0400),
      ldh(0x4F, 0),
      palette_copy(@cgb_bg_palette, 0x68, 0x69),
      palette_copy(@cgb_obj_palette, 0x6A, 0x6B),
      ldh(0x42, 0),
      ldh(0x43, 0),
      ldh(0x4A, 0),
      ldh(0x4B, 87),
      # The aligned source page is copied by real OAM DMA after this write.
      ldh(0x46, @cgb_oam >>> 8),
      # Window/map 9C00, unsigned tile data, sprites, background, LCD on.
      ldh(0x40, 0xF3),
      <<0x18, 0xFE>>
    ])
  end

  defp ldh(register, value), do: <<0x3E, value, 0xE0, register>>

  defp copy(source, destination, length),
    do:
      <<0x21, source::little-16, 0x11, destination::little-16, 0x01, length::little-16, 0xCD,
        @copy::little-16>>

  defp cgb_copy(source, destination, length),
    do:
      <<0x21, source::little-16, 0x11, destination::little-16, 0x01, length::little-16, 0xCD,
        @cgb_copy::little-16>>

  defp palette_copy(source, index_register, data_register),
    do:
      <<0x3E, 0x80, 0xE0, index_register, 0x21, source::little-16, 0x06, 64, 0x0E, data_register,
        0xCD, @cgb_palette_copy::little-16>>

  # LD A,(HL+); LD (DE),A; INC DE; DEC BC; LD A,B; OR C; JR NZ,-8; RET
  defp copy_routine, do: <<0x2A, 0x12, 0x13, 0x0B, 0x78, 0xB1, 0x20, 0xF8, 0xC9>>

  # LD A,(HL+); LDH (C),A; DEC B; JR NZ,-5; RET
  defp palette_copy_routine, do: <<0x2A, 0xE2, 0x05, 0x20, 0xFB, 0xC9>>

  defp tile_data do
    [
      solid_tile(0),
      solid_tile(1),
      solid_tile(2),
      solid_tile(3),
      pixel_tile(fn x, y -> if abs(x - 3) + abs(y - 3) <= 3, do: 3, else: 0 end)
    ]
    |> IO.iodata_to_binary()
  end

  defp cgb_tile_data do
    [
      solid_tile(0),
      pixel_tile(fn x, y -> if rem(x + y, 2) == 0, do: 1, else: 2 end),
      pixel_tile(fn x, _y -> if x < 4, do: 2, else: 3 end),
      pixel_tile(fn x, y -> if x == y or x + y == 7, do: 3, else: 1 end),
      pixel_tile(fn x, y -> if abs(x - 3) + abs(y - 3) <= 3, do: 2, else: 0 end)
    ]
    |> IO.iodata_to_binary()
  end

  defp solid_tile(shade), do: pixel_tile(fn _x, _y -> shade end)

  defp pixel_tile(pixel) do
    for y <- 0..7, into: <<>> do
      {low, high} =
        Enum.reduce(0..7, {0, 0}, fn x, {low, high} ->
          shade = pixel.(x, y)
          bit = 7 - x
          {low ||| (shade &&& 1) <<< bit, high ||| (shade >>> 1 &&& 1) <<< bit}
        end)

      <<low, high>>
    end
  end

  defp tilemap(kind) do
    for y <- 0..31, x <- 0..31, into: <<>> do
      <<tile(kind, x, y)>>
    end
  end

  defp cgb_tilemap_attributes(kind) do
    for y <- 0..31, x <- 0..31, into: <<>> do
      palette = cgb_palette(kind, x, y)
      bank = if rem(x + y, 3) == 0, do: 0x08, else: 0
      x_flip = if rem(x, 5) == 1, do: 0x20, else: 0
      y_flip = if rem(y, 5) == 2, do: 0x40, else: 0
      priority = if cgb_priority?(kind, x, y), do: 0x80, else: 0
      <<palette ||| bank ||| x_flip ||| y_flip ||| priority>>
    end
  end

  defp cgb_palette(:background, x, y), do: rem(div(x, 5) + div(y, 4), 4)
  defp cgb_palette(:window, x, y), do: 4 + rem(div(x, 3) + div(y, 4), 4)

  defp cgb_priority?(:background, x, y), do: x in [0, 19] or y in [0, 17]
  defp cgb_priority?(:window, x, y), do: x in [0, 9] or y in [0, 17]

  defp tile(:background, x, y) when x in 0..19 and y in 0..17 do
    cond do
      x in [0, 19] or y in [0, 17] -> 2
      letter_g?(x, y) -> 3
      true -> 1
    end
  end

  defp tile(:background, _x, _y), do: 0

  defp tile(:window, x, y) when x in 0..9 and y in 0..17 do
    cond do
      x in [0, 9] or y in [0, 17] -> 2
      letter_b?(x, y) -> 3
      true -> 0
    end
  end

  defp tile(:window, _x, _y), do: 0

  # Six-by-nine tile glyphs occupying the left and right halves respectively.
  defp letter_g?(x, y) do
    x = x - 2
    y = y - 4

    y in 0..8 and x in 0..5 and
      (y in [0, 8] or x == 0 or (y >= 4 and x == 5) or (y == 4 and x >= 3))
  end

  defp letter_b?(x, y) do
    x = x - 2
    y = y - 4

    y in 0..8 and x in 0..5 and
      (x == 0 or y in [0, 4, 8] or (x == 5 and y not in [0, 4, 8]))
  end

  defp oam_data do
    for x <- [24, 48, 72, 96], into: <<>>, do: <<144, x, 4, 0>>
  end

  defp cgb_oam_data do
    sprites =
      for {x, attrs} <- [{24, 0x04}, {48, 0x0D}, {72, 0x26}, {96, 0x87}], into: <<>> do
        <<64, x, 4, attrs>>
      end

    sprites <> :binary.copy(<<0>>, 0xA0 - byte_size(sprites))
  end

  defp cgb_bg_palette do
    palette_binary([
      [0x7FFF, 0x5F7F, 0x2D5F, 0x0010],
      [0x7FFF, 0x03FF, 0x01BF, 0x00CC],
      [0x7FFF, 0x3FE0, 0x16A0, 0x0520],
      [0x7FFF, 0x7E5F, 0x7C1F, 0x4010],
      [0x7FFF, 0x7F40, 0x7D20, 0x4400],
      [0x7FFF, 0x7CFF, 0x681F, 0x300F],
      [0x7FFF, 0x57EA, 0x2EA5, 0x1142],
      [0x7FFF, 0x6318, 0x4210, 0x2108]
    ])
  end

  defp cgb_obj_palette do
    palette_binary([
      [0, 0x001F, 0x03FF, 0x7FFF],
      [0, 0x03E0, 0x7FE0, 0x7FFF],
      [0, 0x7C00, 0x7C1F, 0x7FFF],
      [0, 0x021F, 0x7E00, 0x7FFF],
      [0, 0x001F, 0x021F, 0x7FFF],
      [0, 0x03E0, 0x02DF, 0x7FFF],
      [0, 0x7C00, 0x7C18, 0x7FFF],
      [0, 0x03FF, 0x7FE0, 0x7FFF]
    ])
  end

  defp palette_binary(palettes) do
    for color <- List.flatten(palettes), into: <<>>, do: <<color::little-16>>
  end

  defp with_header_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x0134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x014D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
