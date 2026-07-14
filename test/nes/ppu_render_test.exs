defmodule Beamicom.NES.PPURenderTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{PPU, Framebuffer}

  @moduledoc """
  Deterministic background-render test (spec §5.2 item 1, §6). Places a known
  tile at the top-left of the nametable and checks the emitted framebuffer's
  palette-RAM-address pixels — no external reference needed.
  """

  # 8KB CHR: tile 0 blank; tile 1 = solid pattern bit 0 set (every pixel = 1).
  defp chr do
    tile1 = :binary.copy(<<0xFF>>, 8) <> :binary.copy(<<0x00>>, 8)
    <<0::128>> <> tile1 <> <<0::size((8192 - 32) * 8)>>
  end

  test "renders a background tile into palette-address pixels" do
    # Background enabled; nametable entry (0,0) points at tile 1. v/t start at 0
    # so rendering scans from the top-left of nametable 0.
    # 0x0A = enable background + show it in the left 8px (no clip).
    ppu = %{PPU.new(chr(), :horizontal) | mask: 0x0A, vram: %{0 => 1}}

    # Three frames: frame 1+ is correct (its first line was prefetched during
    # the prior pre-render scanline).
    ppu = PPU.run(ppu, 89_342 * 3)
    fb = ppu.frame_ready

    assert %Framebuffer{width: 256, height: 240} = fb
    assert byte_size(fb.pixels) == 256 * 240

    # Top-left 8 pixels come from tile 1 (pattern 1, attribute 0 → address 1);
    # the next tile is blank (address 0).
    assert binary_part(fb.pixels, 0, 8) == <<1, 1, 1, 1, 1, 1, 1, 1>>
    assert :binary.at(fb.pixels, 8) == 0

    # Second row (still tile 1, which is solid on all 8 rows).
    assert binary_part(fb.pixels, 256, 8) == <<1, 1, 1, 1, 1, 1, 1, 1>>
  end

  test "attribute bits select the palette (upper two address bits)" do
    # Put tile 1 across the top row and set attribute quadrant (0,0) to palette 2.
    # Attribute byte $23C0 low 2 bits = palette for the top-left 2x2 tile group.
    ppu = %{
      PPU.new(chr(), :horizontal)
      | mask: 0x0A,
        vram: %{0 => 1, 0x3C0 => 0x02}
    }

    ppu = PPU.run(ppu, 89_342 * 3)
    # attribute 2 (0b10) << 2 | pattern 1 = 0b1001 = 9.
    assert :binary.at(ppu.frame_ready.pixels, 0) == 9
  end
end
