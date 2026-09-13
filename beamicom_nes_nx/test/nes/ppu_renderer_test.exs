defmodule Beamicom.NES.Nx.PPURendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.{PPU, Palette}

  setup do
    previous = Application.get_env(:beamicom_nes, :apu_renderer, :native)
    Application.put_env(:beamicom_nes, :apu_renderer, :native)
    on_exit(fn -> Application.put_env(:beamicom_nes, :apu_renderer, previous) end)
  end

  defp chr do
    tile1 = :binary.copy(<<0xAA>>, 8) <> :binary.copy(<<0x55>>, 8)
    tile2 = :binary.copy(<<0xF0>>, 8) <> :binary.copy(<<0x0F>>, 8)
    <<0::128>> <> tile1 <> tile2 <> <<0::size((8192 - 48) * 8)>>
  end

  defp scene(renderer, opts \\ []) do
    # Repeating nontrivial background plus overlapping front/behind sprites makes
    # the comparison cover bit extraction, attributes, clipping and OAM priority.
    tiles = for i <- 0..959, into: <<>>, do: <<1 + rem(i, 2)>>
    vram = tiles <> <<0::size((0x800 - byte_size(tiles)) * 8)>>
    sprites = <<30, 2, 0x00, 40, 30, 1, 0x21, 44, 70, 2, 0x20, 4>>
    oam = sprites <> :binary.copy(<<0xFF, 0, 0, 0>>, 61)

    palette = Map.new(0..31, &{&1, rem(&1 * 7, 64)})

    ppu = %{
      PPU.new(chr(), :horizontal)
      | mask: Keyword.get(opts, :mask, 0x1E),
        vram: vram,
        oam: oam,
        palette: palette,
        chr_latch: Keyword.get(opts, :chr_latch)
    }

    ppu
    |> PPU.set_renderer(renderer)
    |> PPU.set_enhancement(:hide_horizontal_overscan, Keyword.get(opts, :overscan, false))
    |> PPU.run(89_342 * 3)
  end

  test "frame-wide Nx composition is pixel-exact with native composition" do
    native = scene(:native)
    nx = scene(:nx)

    assert nx.frame_ready.pixels == native.frame_ready.pixels
    assert nx.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
    assert Palette.to_rgb(nx.frame_ready) == Palette.to_rgb(native.frame_ready)
    assert nx.status == native.status
    assert byte_size(nx.frame_ready.pixels) == 256 * 240
  end

  test "Nx RGB expansion applies grayscale and presentation edge masking" do
    native = scene(:native, mask: 0x1F, overscan: true)
    nx = scene(:nx, mask: 0x1F, overscan: true)

    assert nx.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
    assert binary_part(nx.frame_ready.rgb, 0, 8 * 3) == <<0::size(8 * 3 * 8)>>
  end

  test "resident CHR atlas rendering is pixel-exact with native composition" do
    native = scene(:native)
    atlas = scene(:nx_atlas)

    refute is_nil(atlas.renderer_state)
    assert atlas.frame_ready.pixels == native.frame_ready.pixels
    assert atlas.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
    assert atlas.status == native.status
  end

  test "atlas renderer falls back to byte capture for CHR-latch cartridges" do
    latch = %{l0: :fd, l1: :fd, fd0: 0, fe0: 0, fd1: 0x1000, fe1: 0x1000}
    native = scene(:native, chr_latch: latch)
    fallback = scene(:nx_atlas, chr_latch: latch)

    refute is_nil(fallback.renderer_state)
    assert fallback.frame_ready.pixels == native.frame_ready.pixels
    assert fallback.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
  end
end
