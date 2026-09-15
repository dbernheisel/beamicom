defmodule Beamicom.NES.Nx.PPURendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.{PPU, Palette}
  alias Beamicom.NES.Nx.PPURenderer

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

    palette =
      Map.new(0..31, &{&1, rem(&1 * 7, 64)})
      |> Map.put(17, Keyword.get(opts, :sprite_color, 55))

    chr_ram? = Keyword.get(opts, :chr_ram, false)
    chr = chr()

    ppu = %{
      PPU.new(if(chr_ram?, do: <<>>, else: chr), :horizontal)
      | mask: Keyword.get(opts, :mask, 0x1E),
        vram: vram,
        oam: oam,
        palette: palette,
        chr_ram:
          if(chr_ram?,
            do:
              chr
              |> :binary.bin_to_list()
              |> Enum.with_index()
              |> Map.new(fn {v, i} -> {i, v} end),
            else: %{}
          ),
        chr_latch: Keyword.get(opts, :chr_latch)
    }

    ppu =
      ppu
      |> PPU.set_renderer(renderer)
      |> PPU.set_enhancement(:hide_horizontal_overscan, Keyword.get(opts, :overscan, false))
      |> PPU.set_enhancement(:unlimited_sprites, Keyword.get(opts, :unlimited_sprites, false))
      |> PPU.run(89_342 * Keyword.get(opts, :frames, 3))

    %{ppu | frame_ready: PPU.resolve_frame(ppu.frame_ready)}
  end

  defp rgb_at(frame, x, y), do: binary_part(frame.rgb, (y * 256 + x) * 3, 3)

  test "atlas-backed Nx composition is pixel-exact with native composition" do
    native = scene(:native)
    nx = scene(:nx)

    refute is_nil(nx.renderer_state)
    assert nx.frame_ready.pixels == native.frame_ready.pixels
    assert nx.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
    assert Palette.to_rgb(nx.frame_ready) == Palette.to_rgb(native.frame_ready)
    assert nx.status == native.status
    assert byte_size(nx.frame_ready.pixels) == 256 * 240
  end

  test "runtime :nx shorthand selects the atlas renderer" do
    ppu = PPU.new(chr(), :horizontal, ppu_renderer: :nx)
    assert ppu.renderer == Beamicom.NES.Nx.PPURenderer
    refute is_nil(ppu.renderer_state)
  end

  test "Nx RGB expansion applies grayscale and presentation edge masking" do
    native = scene(:native, mask: 0x1F, overscan: true)
    nx = scene(:nx, mask: 0x1F, overscan: true)

    assert nx.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
    assert binary_part(nx.frame_ready.rgb, 0, 8 * 3) == <<0::size(8 * 3 * 8)>>
  end

  test "atlas renderer falls back to byte capture for CHR-latch cartridges" do
    latch = %{l0: :fd, l1: :fd, fd0: 0, fe0: 0, fd1: 0x1000, fe1: 0x1000}
    native = scene(:native, chr_latch: latch)
    fallback = scene(:nx, chr_latch: latch)

    refute is_nil(fallback.renderer_state)
    assert fallback.frame_ready.pixels == native.frame_ready.pixels
    assert fallback.frame_ready.rgb == Palette.to_rgb(native.frame_ready)
  end

  test "lighting changes RGB only for explicitly selected CHR sprite pixels" do
    base = scene(:nx)

    lighting = [
      radius: 3,
      sigma: 1.5,
      strength: 1.25,
      emitters: [
        [
          layer: :sprite,
          tile_space: :chr,
          tiles: [2],
          subpalettes: [0],
          color_slots: [1]
        ]
      ]
    ]

    lit = scene({PPURenderer, lighting: lighting})

    assert lit.frame_ready.pixels == base.frame_ready.pixels
    refute lit.frame_ready.rgb == base.frame_ready.rgb
    refute rgb_at(lit.frame_ready, 40, 31) == rgb_at(base.frame_ready, 40, 31)
    assert rgb_at(lit.frame_ready, 200, 200) == rgb_at(base.frame_ready, 200, 200)

    recolored = scene({PPURenderer, lighting: lighting}, sprite_color: 0x27)

    assert recolored.frame_ready.pixels == lit.frame_ready.pixels
    refute rgb_at(recolored.frame_ready, 38, 31) == rgb_at(lit.frame_ready, 38, 31)

    nonmatching =
      scene(
        {PPURenderer, lighting: put_in(lighting, [:emitters, Access.at(0), :color_slots], [3])}
      )

    assert nonmatching.frame_ready.pixels == base.frame_ready.pixels
    assert nonmatching.frame_ready.rgb == base.frame_ready.rgb
  end

  test "lighting can select source rows within an emitting tile" do
    base = scene(:nx)

    lighting = [
      radius: 1,
      sigma: 0.5,
      strength: 1.25,
      emitters: [
        [
          layer: :sprite,
          tile_space: :chr,
          tiles: [2],
          subpalettes: [0],
          color_slots: [1],
          rows: [0]
        ]
      ]
    ]

    lit = scene({PPURenderer, lighting: lighting})

    assert lit.frame_ready.pixels == base.frame_ready.pixels
    refute rgb_at(lit.frame_ready, 40, 31) == rgb_at(base.frame_ready, 40, 31)
    assert rgb_at(lit.frame_ready, 40, 38) == rgb_at(base.frame_ready, 40, 38)
  end

  test "lighting can identify sprites by logical PPU tile in CHR RAM" do
    base = scene(:nx, chr_ram: true)

    lit =
      scene(
        {PPURenderer,
         lighting: [
           radius: 2,
           strength: 1.0,
           emitters: [
             [
               layer: :sprite,
               tile_space: :ppu,
               tiles: [2],
               subpalettes: [0],
               color_slots: [1]
             ]
           ]
         ]},
        chr_ram: true
      )

    assert lit.frame_ready.pixels == base.frame_ready.pixels
    refute lit.frame_ready.rgb == base.frame_ready.rgb
  end

  test "organic flicker is deterministic and changes with the emulated frame" do
    lighting = [
      radius: 3,
      sigma: 1.5,
      strength: 1.25,
      emitters: [
        [
          layer: :sprite,
          tile_space: :chr,
          tiles: [2],
          subpalettes: [0],
          color_slots: [1],
          flicker: [amount: 0.6]
        ]
      ]
    ]

    frame3 = scene({PPURenderer, lighting: lighting}, frames: 3)
    repeated = scene({PPURenderer, lighting: lighting}, frames: 3)
    frame4 = scene({PPURenderer, lighting: lighting}, frames: 4)

    assert repeated.frame_ready.rgb == frame3.frame_ready.rgb
    assert frame4.frame_ready.pixels == frame3.frame_ready.pixels
    refute rgb_at(frame4.frame_ready, 38, 31) == rgb_at(frame3.frame_ready, 38, 31)
  end

  test "lighting retains sprite provenance when the sprite limit is removed" do
    lighting = [
      radius: 3,
      strength: 1.0,
      emitters: [
        [
          layer: :sprite,
          tile_space: :ppu,
          tiles: [2],
          subpalettes: [0],
          color_slots: [1]
        ]
      ]
    ]

    base = scene(:nx, unlimited_sprites: true)
    lit = scene({PPURenderer, lighting: lighting}, unlimited_sprites: true)

    assert lit.frame_ready.pixels == base.frame_ready.pixels
    refute lit.frame_ready.rgb == base.frame_ready.rgb
    refute rgb_at(lit.frame_ready, 40, 31) == rgb_at(base.frame_ready, 40, 31)
  end
end
