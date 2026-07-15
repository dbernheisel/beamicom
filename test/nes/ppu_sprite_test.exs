defmodule Beamicom.NES.PPUSpriteTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.NES.PPU

  @moduledoc """
  Deterministic sprite tests (spec §5.2 item 4): OAM evaluation, pattern fetch,
  priority compositing, and sprite-0 hit — verified against a controlled scene,
  no external ROM needed.
  """

  # tile 1 = solid pattern-1 (every pixel opaque, palette entry 1).
  defp chr do
    tile1 = :binary.copy(<<0xFF>>, 8) <> :binary.copy(<<0x00>>, 8)
    <<0::128>> <> tile1 <> <<0::size((8192 - 32) * 8)>>
  end

  # Background: whole nametable = tile 1 (opaque everywhere, address 1).
  # 2KB VRAM: page-0 tiles (offsets 0..959) all = tile 1; rest blank.
  defp full_bg, do: :binary.copy(<<1>>, 960) <> <<0::size((0x800 - 960) * 8)>>

  # 256-byte OAM with only sprite 0 set; the rest are Y=0 (off-screen for the
  # scanlines these tests inspect).
  defp oam(y, tile, attr, x), do: <<y, tile, attr, x, 0::size(252 * 8)>>

  # Run until we reach post-render of a rendered frame (hit flag not yet cleared).
  defp run_to_post_render(ppu) do
    Enum.reduce_while(1..400_000, ppu, fn _, p ->
      p = PPU.run(p, 1)
      if p.scanline == 240 and p.frame >= 1, do: {:halt, p}, else: {:cont, p}
    end)
  end

  test "sprite 0 over opaque background sets the hit flag and draws in front" do
    # Sprite 0: OAM Y=30 (renders scanlines 31..38), tile 1, attr 0 (front,
    # palette 0), X=40. bg+sprites enabled, no left clip.
    oam = oam(30, 1, 0x00, 40)
    ppu = %{PPU.new(chr(), :horizontal) | mask: 0x1E, vram: full_bg(), oam: oam}

    ppu = run_to_post_render(ppu)

    # Sprite-0 hit occurred.
    assert (ppu.status &&& 0x40) != 0

    px = fn line, x -> :binary.at(ppu.frame_ready.pixels, line * 256 + x) end
    # Inside the sprite (front priority): sprite palette address $10 | pattern 1.
    assert px.(32, 42) == 0x11
    # Outside the sprite: background address 1.
    assert px.(32, 100) == 0x01
  end

  test "behind-priority sprite is hidden by opaque background" do
    # attr bit 5 set → sprite behind background.
    oam = oam(30, 1, 0x20, 40)
    ppu = %{PPU.new(chr(), :horizontal) | mask: 0x1E, vram: full_bg(), oam: oam}
    ppu = run_to_post_render(ppu)

    # Background wins the pixel, but the hit still registers (both opaque).
    assert (ppu.status &&& 0x40) != 0
    assert :binary.at(ppu.frame_ready.pixels, 32 * 256 + 42) == 0x01
  end

  test "sprite shows over a transparent (disabled) background" do
    oam = oam(30, 1, 0x00, 40)
    # Sprites only (bit 4), background off (bit 3 clear).
    ppu = %{PPU.new(chr(), :horizontal) | mask: 0x14, vram: full_bg(), oam: oam}
    ppu = run_to_post_render(ppu)

    # No hit (background rendering off), sprite drawn over backdrop.
    assert (ppu.status &&& 0x40) == 0
    assert :binary.at(ppu.frame_ready.pixels, 32 * 256 + 42) == 0x11
  end
end
