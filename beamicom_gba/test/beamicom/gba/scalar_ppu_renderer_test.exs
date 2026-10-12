defmodule Beamicom.GBA.ScalarPPURendererTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.ScalarPPURenderer
  alias Beamicom.GBA.PPU.ColorCorrection

  test "expands mode-3 BGR555 pixels into RGB24" do
    pixels = <<0x001F::little-16, 0x03E0::little-16, 0x7C00::little-16, 0x7FFF::little-16>>
    vram = pixels <> :binary.copy(<<0>>, 240 * 160 * 2 - byte_size(pixels))
    frame = ScalarPPURenderer.render_mode3(vram)

    assert binary_part(frame, 0, 12) ==
             <<221, 24, 26, 85, 223, 72, 0, 103, 230, 255, 255, 255>>

    assert byte_size(frame) == 240 * 160 * 3
  end

  test "renders a regular 4bpp mode-0 background" do
    tile = :binary.copy(<<0x11>>, 32)
    vram = tile <> :binary.copy(<<0>>, 96 * 1024 - byte_size(tile))
    palette = <<0x0000::little-16, 0x001F::little-16>> <> :binary.copy(<<0>>, 1_020)
    oam = hidden_oam()

    registers = %{
      dispcnt: 0x0100,
      bgcnt: {0x0100, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    assert binary_part(frame, 0, 8 * 3) == :binary.copy(ColorCorrection.rgb24(0x001F), 8)
    assert byte_size(frame) == 240 * 160 * 3
  end

  test "uses background control captured for each scanline" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0, <<0x21>>)
      |> replace(4, <<0x21>>)
      |> replace(8, <<0x21>>)

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x03E0::little-16>>)
      |> replace(33 * 2, <<0x001F::little-16>>)

    scanline_bgcnt =
      List.duplicate({0x1F00, 0, 0, 0}, 160)
      |> List.replace_at(0, {0x1F80, 0, 0, 0})
      |> List.to_tuple()

    registers = %{
      dispcnt: 0x0100,
      bgcnt: {0x1F00, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      scanline_bgcnt: scanline_bgcnt
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, 240 * 3, 3) == ColorCorrection.rgb24(0x03E0)
  end

  test "renders a regular object above a same-priority background" do
    background_tile = :binary.copy(<<0x11>>, 32)
    object_tile = :binary.copy(<<0x11>>, 32)

    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0, background_tile)
      |> replace(0x10_000, object_tile)

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)
      |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

    first_object = <<0x0000::little-16, 0x0000::little-16, 0x0400::little-16, 0::16>>
    oam = replace(hidden_oam(), 0, first_object)

    registers = %{
      dispcnt: 0x1100,
      bgcnt: {0x0101, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    assert binary_part(frame, 0, 8 * 3) == :binary.copy(ColorCorrection.rgb24(0x03E0), 8)
    assert binary_part(frame, 8 * 3, 3) == ColorCorrection.rgb24(0x001F)
  end

  test "renders an affine object with its OAM matrix" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x10_000, :binary.copy(<<0x11>>, 32))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

    oam =
      hidden_oam()
      |> replace(0, <<0x0100::little-16, 0x0000::little-16, 0x0000::little-16>>)
      |> replace(6, <<0x0100::little-16>>)
      |> replace(14, <<0x0000::little-16>>)
      |> replace(22, <<0x0000::little-16>>)
      |> replace(30, <<0x0100::little-16>>)

    registers = %{
      dispcnt: 0x1000,
      bgcnt: {0, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    assert binary_part(frame, 0, 8 * 3) == :binary.copy(ColorCorrection.rgb24(0x03E0), 8)
    assert binary_part(frame, 8 * 3, 3) == <<0, 0, 0>>
  end

  test "wraps a double-size affine object according to its displayed height" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x10_000, :binary.copy(<<0x11>>, 2_048))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

    oam =
      hidden_oam()
      |> replace(0, <<0x039F::little-16, 0xC000::little-16, 0x0000::little-16>>)
      |> replace(6, <<0x0080::little-16>>)
      |> replace(14, <<0x0000::little-16>>)
      |> replace(22, <<0x0000::little-16>>)
      |> replace(30, <<0x0080::little-16>>)

    registers = %{
      dispcnt: 0x1040,
      bgcnt: {0, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x03E0)
    assert binary_part(frame, 159 * 240 * 3, 3) == <<0, 0, 0>>
  end

  test "alpha blends a semi-transparent object with the background" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0, :binary.copy(<<0x11>>, 32))
      |> replace(0x10_000, :binary.copy(<<0x11>>, 32))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)
      |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

    first_object = <<0x0400::little-16, 0x0000::little-16, 0x0000::little-16, 0::16>>
    oam = replace(hidden_oam(), 0, first_object)

    registers = %{
      dispcnt: 0x1100,
      bgcnt: {0x0100, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      display_effects: {0, 0, 0, 0, 0, 0, 0, 0, 0x0140, 0x0808, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x01EF)
  end

  test "darkens a selected background target" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0, :binary.copy(<<0x11>>, 32))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)

    registers = %{
      dispcnt: 0x0100,
      bgcnt: {0x0100, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      display_effects: {0, 0, 0, 0, 0, 0, 0, 0, 0x00C1, 0, 8}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x0010)
  end

  test "applies background masks inside and outside a regular window" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x20, :binary.copy(<<0x11>>, 32))
      |> replace(0x40, :binary.copy(<<0x22>>, 32))
      |> replace(0x800, :binary.copy(<<1::little-16>>, 33))
      |> replace(0x1000, :binary.copy(<<2::little-16>>, 33))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)
      |> replace(4, <<0x03E0::little-16>>)

    registers = %{
      dispcnt: 0x2300,
      bgcnt: {0x0100, 0x0201, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      display_effects: {0x0008, 0, 0x0008, 0, 0x0002, 0x0001, 0, 0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)

    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x03E0)
    assert binary_part(frame, 8 * 3, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, 8 * 240 * 3, 3) == ColorCorrection.rgb24(0x001F)
  end

  test "only applies color effects where the window enables them" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x20, :binary.copy(<<0x11>>, 32))
      |> replace(0x800, :binary.copy(<<1::little-16>>, 2))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)

    registers = %{
      dispcnt: 0x2100,
      bgcnt: {0x0100, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      display_effects: {0x0008, 0, 0x0008, 0, 0x0001, 0x0021, 0, 0, 0x00C1, 0, 8}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)

    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, 8 * 3, 3) == ColorCorrection.rgb24(0x0010)
  end

  test "uses non-transparent OBJ-window pixels as a window mask" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x20, :binary.copy(<<0x11>>, 32))
      |> replace(0x800, :binary.copy(<<1::little-16>>, 2))
      |> replace(0x10_000, :binary.copy(<<0x11>>, 32))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)

    object_window = <<0x0800::little-16, 0::little-16, 0::little-16, 0::little-16>>
    oam = replace(hidden_oam(), 0, object_window)

    registers = %{
      dispcnt: 0x9100,
      bgcnt: {0x0100, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      display_effects: {0, 0, 0, 0, 0, 0x0001, 0, 0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)

    assert binary_part(frame, 0, 3) == <<0, 0, 0>>
    assert binary_part(frame, 8 * 3, 3) == ColorCorrection.rgb24(0x001F)
  end

  test "renders a Mode 1 affine background with transparent overflow" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x4000, :binary.copy(<<1>>, 64))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(0, <<0x7C00::little-16>>)
      |> replace(2, <<0x001F::little-16>>)

    registers = %{
      dispcnt: 0x0401,
      bgcnt: {0, 0, 0x0004, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      bg_affine: {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}}
    }

    frame = ScalarPPURenderer.render_mode1(vram, palette, hidden_oam(), registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, (127 * 240 + 127) * 3, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, 128 * 3, 3) == ColorCorrection.rgb24(0x7C00)
    assert byte_size(frame) == 240 * 160 * 3
  end

  test "renders Mode 0 and Mode 1 from their captured scanline registers" do
    vram =
      :binary.copy(<<0>>, 96 * 1024)
      |> replace(0x20, :binary.copy(<<0x11>>, 32))
      |> replace(0x800, <<1::little-16>>)
      |> replace(0x4000 + 2 * 64, :binary.copy(<<2>>, 64))
      |> replace(0x1000, <<2>>)

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace(2, <<0x001F::little-16>>)
      |> replace(4, <<0x03E0::little-16>>)

    scanline_dispcnt = List.duplicate(0x0401, 160) |> List.replace_at(0, 0x0400)

    scanline_bgcnt =
      List.duplicate({0, 0, 0x0204, 0}, 160)
      |> List.replace_at(0, {0, 0, 0x0100, 0})

    registers = %{
      dispcnt: 0x0400,
      bgcnt: {0, 0, 0x0100, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0},
      bg_affine: {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}},
      scanline_dispcnt: List.to_tuple(scanline_dispcnt),
      scanline_bgcnt: List.to_tuple(scanline_bgcnt)
    }

    frame = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
    assert binary_part(frame, 0, 3) == ColorCorrection.rgb24(0x001F)
    assert binary_part(frame, 240 * 3, 3) == ColorCorrection.rgb24(0x03E0)
  end

  test "renders regular objects from the bitmap-mode object tile range" do
    background = :binary.copy(<<0x001F::little-16>>, 240 * 160)

    vram =
      (background <> :binary.copy(<<0>>, 96 * 1024 - byte_size(background)))
      |> replace(0x14_000, :binary.copy(<<0x11>>, 32))

    palette =
      :binary.copy(<<0>>, 1024)
      |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

    first_object = <<0x0000::little-16, 0x0000::little-16, 0x0200::little-16, 0::16>>
    oam = replace(hidden_oam(), 0, first_object)

    registers = %{
      dispcnt: 0x1403,
      bgcnt: {0, 0, 0, 0},
      bghofs: {0, 0, 0, 0},
      bgvofs: {0, 0, 0, 0}
    }

    frame = ScalarPPURenderer.render_mode3(vram, palette, oam, registers)
    assert binary_part(frame, 0, 8 * 3) == :binary.copy(ColorCorrection.rgb24(0x03E0), 8)
    assert binary_part(frame, 8 * 3, 3) == ColorCorrection.rgb24(0x001F)
  end

  defp hidden_oam do
    :binary.copy(<<0x0200::little-16, 0::little-16, 0::little-16, 0::little-16>>, 128)
  end

  defp replace(binary, offset, replacement) do
    size = byte_size(replacement)
    <<prefix::binary-size(^offset), _old::binary-size(^size), suffix::binary>> = binary
    prefix <> replacement <> suffix
  end
end
