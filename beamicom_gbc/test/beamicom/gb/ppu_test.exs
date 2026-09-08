defmodule Beamicom.GB.PPUTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.PPU

  @line_dots 456
  @frame_dots 456 * 154
  @identity_palette 0xE4

  test "advances between LCD modes in batches and stops completely with LCD off" do
    ppu = PPU.new(lcdc: 0x80, stat: 0x08)
    assert PPU.mode(ppu) == 2
    assert PPU.ly(ppu) == 0
    assert PPU.dot(ppu) == 0

    {ppu, []} = PPU.tick(ppu, 79)
    assert {PPU.mode(ppu), PPU.dot(ppu)} == {2, 79}

    {ppu, []} = PPU.tick(ppu, 1)
    assert {PPU.mode(ppu), PPU.dot(ppu)} == {3, 80}

    {ppu, [:lcd_stat]} = PPU.tick(ppu, 172)
    assert {PPU.mode(ppu), PPU.dot(ppu)} == {0, 252}

    {ppu, []} = PPU.tick(ppu, 204)
    assert {PPU.ly(ppu), PPU.mode(ppu), PPU.dot(ppu)} == {1, 2, 0}

    {ppu, []} = PPU.write(ppu, 0xFF40, 0)
    {same, []} = PPU.tick(ppu, 10_000)
    assert same == ppu
    assert PPU.read(same, 0xFF44) == 0
    assert (PPU.read(same, 0xFF41) &&& 0x03) == 0
  end

  test "reports LYC and VBlank interrupt edges and completed frames explicitly" do
    ppu = PPU.new(lcdc: 0x80, stat: 0x40, lyc: 1)
    {ppu, [:lcd_stat]} = PPU.tick(ppu, @line_dots)
    assert PPU.ly(ppu) == 1
    assert (PPU.read(ppu, 0xFF41) &&& 0x04) != 0

    {ppu, []} = PPU.write(ppu, 0xFF41, 0x10)
    {ppu, signals} = PPU.tick(ppu, @line_dots * 143)

    assert PPU.ly(ppu) == 144
    assert PPU.mode(ppu) == 1
    assert [{:frame, 0, frame}, :vblank, :lcd_stat] = signals
    assert byte_size(frame) == 160 * 144

    {ppu, signals} = PPU.tick(ppu, @line_dots * 10)
    assert PPU.ly(ppu) == 0
    assert PPU.mode(ppu) == 2
    assert signals == []
  end

  test "small in-mode tick fast paths match one exact full-frame batch" do
    ppu =
      PPU.new(model: :cgb, lcdc: 0xF3, stat: 0x78, lyc: 73, scx: 5, wy: 2, wx: 9)
      |> PPU.load_vram(
        0x0000,
        tile_from_rows(List.duplicate(Enum.to_list(0..3) ++ [0, 1, 2, 3], 8))
      )
      |> PPU.load_vram(0x0010, solid_tile(2))
      |> PPU.load_vram(0x1800, :binary.copy(<<0, 1>>, 0x200))
      |> PPU.load_vram(0x3800, :binary.copy(<<0x21, 0xC2>>, 0x200))
      |> PPU.load_oam(0, <<16, 8, 1, 0x00, 16, 12, 0, 0xA1>>)
      |> put_cgb_color(:bg, 0, 1, 0x001F)
      |> put_cgb_color(:bg, 0, 2, 0x03E0)
      |> put_cgb_color(:obj, 0, 2, 0x7C00)

    {batched, batched_signals} = PPU.tick(ppu, @frame_dots)

    {chunked, chunked_signals, 0} =
      Stream.cycle([1, 2, 3, 4, 5, 6, 7])
      |> Enum.reduce_while({ppu, [], @frame_dots}, fn chunk, {ppu, signals, remaining} ->
        count = min(chunk, remaining)
        {ppu, emitted} = PPU.tick(ppu, count)
        next = {ppu, signals ++ emitted, remaining - count}
        if remaining == count, do: {:halt, next}, else: {:cont, next}
      end)

    assert chunked == batched
    assert chunked_signals == batched_signals
  end

  test "register writes can expose an immediate combined STAT rising edge" do
    ppu = PPU.new(lcdc: 0x80, stat: 0x40, lyc: 1)
    assert {ppu, [:lcd_stat]} = PPU.write(ppu, 0xFF45, 0)
    assert (PPU.read(ppu, 0xFF41) &&& 0x04) != 0

    assert {ppu, []} = PPU.write(ppu, 0xFF41, 0x28)
    assert {ppu, [:lcd_stat]} = PPU.tick(ppu, 252)
    assert PPU.mode(ppu) == 0
  end

  test "enforces VRAM and OAM access windows with static mode heads" do
    ppu =
      PPU.new(lcdc: 0)
      |> PPU.load_vram(0, <<0x12>>)
      |> PPU.load_oam(0, <<0x34>>)

    assert PPU.read(ppu, 0x8000) == 0x12
    assert PPU.read(ppu, 0xFE00) == 0x34

    {ppu, []} = PPU.write(ppu, 0xFF40, 0x80)
    assert PPU.mode(ppu) == 2
    assert PPU.read(ppu, 0x8000) == 0x12
    assert PPU.read(ppu, 0xFE00) == 0xFF

    {ppu, []} = PPU.tick(ppu, 80)
    assert PPU.read(ppu, 0x8000) == 0xFF
    assert PPU.read(ppu, 0xFE00) == 0xFF
    {ppu, []} = PPU.write(ppu, 0x8000, 0xAA)
    {ppu, []} = PPU.write(ppu, 0xFE00, 0xBB)

    {ppu, []} = PPU.tick(ppu, 172)
    assert PPU.read(ppu, 0x8000) == 0x12
    assert PPU.read(ppu, 0xFE00) == 0x34
  end

  test "renders deterministic scrolled background and clipped window scanlines" do
    ppu =
      PPU.new(
        lcdc: 0xF1,
        scx: 4,
        bgp: @identity_palette,
        wy: 0,
        wx: 87
      )
      |> PPU.load_vram(0x0000, solid_tile(1))
      |> PPU.load_vram(0x0010, solid_tile(2))
      |> PPU.load_vram(0x1C00, :binary.copy(<<1>>, 0x400))

    {ppu, signals} = PPU.tick(ppu, @frame_dots)
    assert [{:frame, 0, frame}, :vblank] = signals
    assert PPU.frame(ppu) == frame

    assert binary_part(frame, 0, 160) ==
             :binary.copy(<<1>>, 80) <> :binary.copy(<<2>>, 80)

    assert binary_part(frame, 143 * 160, 160) ==
             :binary.copy(<<1>>, 80) <> :binary.copy(<<2>>, 80)
  end

  test "uses DMG sprite X/OAM priority before background priority" do
    sprites = <<
      16,
      28,
      1,
      0,
      16,
      26,
      2,
      0x80
    >>

    ppu =
      PPU.new(lcdc: 0x93, bgp: @identity_palette, obp0: @identity_palette)
      |> PPU.load_vram(0x0000, solid_tile(1))
      |> PPU.load_vram(0x0010, solid_tile(2))
      |> PPU.load_vram(0x0020, solid_tile(3))
      |> PPU.load_oam(0, sprites)

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)
    line = binary_part(frame, 0, 160)

    # The second object has smaller X and wins overlap selection, but its
    # BG-priority flag then lets nonzero BG win; the lower-priority object
    # cannot show through it. The first object remains visible at x=26..27.
    assert binary_part(line, 18, 10) ==
             :binary.copy(<<1>>, 8) <> :binary.copy(<<2>>, 2)
  end

  test "uses signed tile addressing when LCDC tile-data select is clear" do
    ppu =
      PPU.new(lcdc: 0x81, bgp: @identity_palette)
      |> PPU.load_vram(0x0FF0, solid_tile(3))
      |> PPU.load_vram(0x1800, :binary.copy(<<0xFF>>, 0x400))

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)
    assert binary_part(frame, 0, 160) == :binary.copy(<<3>>, 160)
  end

  test "CGB palette data registers cache RGB24 colors and obey mode-3 access" do
    ppu = PPU.new(model: :cgb, lcdc: 0)
    assert PPU.pixel_format(ppu) == :rgb24
    assert byte_size(PPU.frame(ppu)) == 160 * 144 * 3

    {ppu, []} = PPU.write(ppu, 0xFF68, 0x80 ||| 10)
    {ppu, []} = PPU.write(ppu, 0xFF69, 0x1F)
    {ppu, []} = PPU.write(ppu, 0xFF69, 0x00)
    assert PPU.read(ppu, 0xFF68) == 0x8C

    {ppu, []} = PPU.write(ppu, 0xFF68, 10)
    assert PPU.read(ppu, 0xFF69) == 0x1F
    assert PPU.read(ppu, 0xFF68) == 10

    {ppu, []} = PPU.write(ppu, 0xFF40, 0x80)
    {ppu, []} = PPU.tick(ppu, 80)
    {ppu, []} = PPU.write(ppu, 0xFF68, 0x80 ||| 10)
    {ppu, []} = PPU.write(ppu, 0xFF69, 0x00)
    assert PPU.read(ppu, 0xFF68) == 0x8B
    assert PPU.read(ppu, 0xFF69) == 0xFF

    {ppu, []} = PPU.tick(ppu, 172)
    {ppu, []} = PPU.write(ppu, 0xFF68, 10)
    assert PPU.read(ppu, 0xFF69) == 0x1F

    {ppu, []} = PPU.write(ppu, 0xFF6A, 0xBF)
    {ppu, []} = PPU.write(ppu, 0xFF6B, 0x12)
    assert PPU.read(ppu, 0xFF6A) == 0x80
    {ppu, []} = PPU.write(ppu, 0xFF6A, 63)
    assert PPU.read(ppu, 0xFF6B) == 0x12

    dmg = PPU.new(lcdc: 0)
    assert PPU.read(dmg, 0xFF68) == 0xFF
    assert {^dmg, []} = PPU.write(dmg, 0xFF69, 0x12)
  end

  test "CGB background and window use bank, palette, and flip attributes" do
    patterned =
      tile_from_rows(List.duplicate(List.duplicate(0, 8), 7) ++ [[1, 2, 3, 0, 0, 0, 0, 0]])

    ppu =
      PPU.new(model: :cgb, lcdc: 0xF1, wy: 0, wx: 87)
      |> PPU.load_vram(0x2010, patterned)
      |> PPU.load_vram(0x2020, solid_tile(2))
      |> PPU.load_vram(0x1800, :binary.copy(<<1>>, 0x400))
      |> PPU.load_vram(0x1C00, :binary.copy(<<2>>, 0x400))
      |> PPU.load_vram(0x3800, :binary.copy(<<0x69>>, 0x400))
      |> PPU.load_vram(0x3C00, :binary.copy(<<0x0A>>, 0x400))
      |> put_cgb_color(:bg, 1, 1, 0x001F)
      |> put_cgb_color(:bg, 1, 2, 0x03E0)
      |> put_cgb_color(:bg, 1, 3, 0x7C00)
      |> put_cgb_color(:bg, 2, 2, 0x03FF)

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)
    assert byte_size(frame) == 160 * 144 * 3

    # BG tile row 7 is selected by Y-flip and reversed by X-flip. The window
    # starts at x=80 and selects its own palette and VRAM bank.
    assert binary_part(frame, 0, 24) ==
             rgb(0x7FFF) <>
               rgb(0x7FFF) <>
               rgb(0x7FFF) <>
               rgb(0x7FFF) <>
               rgb(0x7FFF) <> rgb(0x7C00) <> rgb(0x03E0) <> rgb(0x001F)

    assert binary_part(frame, 80 * 3, 8 * 3) == :binary.copy(rgb(0x03FF), 8)
  end

  test "CGB objects use OAM order, object palettes, and tile banks" do
    sprites = <<16, 28, 1, 1, 16, 26, 2, 0x0A>>

    ppu =
      PPU.new(model: :cgb, lcdc: 0x93)
      |> PPU.load_vram(0x0010, solid_tile(1))
      |> PPU.load_vram(0x2020, solid_tile(2))
      |> PPU.load_oam(0, sprites)
      |> put_cgb_color(:obj, 1, 1, 0x001F)
      |> put_cgb_color(:obj, 2, 2, 0x03E0)

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)

    # Object 1 has smaller X, but CGB overlap priority is earlier OAM index.
    assert binary_part(frame, 18 * 3, 10 * 3) ==
             :binary.copy(rgb(0x03E0), 2) <> :binary.copy(rgb(0x001F), 8)
  end

  test "CGB object row composition preserves clipping, transparency, and OAM priority" do
    patterned = tile_from_rows(List.duplicate([1, 0, 2, 0, 3, 0, 1, 0], 8))

    ppu =
      PPU.new(model: :cgb, lcdc: 0x93)
      |> PPU.load_vram(0x0010, patterned)
      |> PPU.load_vram(0x0020, solid_tile(2))
      # The first object starts three pixels left of the screen and is X-flipped.
      # Its transparent pixels reveal the lower-priority solid object.
      |> PPU.load_oam(0, <<16, 5, 1, 0x20, 16, 8, 2, 0x00>>)
      |> put_cgb_color(:obj, 0, 1, 0x001F)
      |> put_cgb_color(:obj, 0, 2, 0x03E0)
      |> put_cgb_color(:obj, 0, 3, 0x7C00)

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)

    expected =
      [0x7C00, 0x03E0, 0x03E0, 0x03E0, 0x001F, 0x03E0, 0x03E0, 0x03E0]
      |> Enum.map_join(&rgb/1)

    assert binary_part(frame, 0, 8 * 3) == expected
  end

  test "CGB BG and object priority flags yield to LCDC master priority" do
    bg_priority = cgb_priority_frame(0x93, 0x81, 0x00)
    obj_priority = cgb_priority_frame(0x93, 0x01, 0x80)
    master_off = cgb_priority_frame(0x92, 0x81, 0x80)

    assert binary_part(bg_priority, 0, 3) == rgb(0x7C00)
    assert binary_part(obj_priority, 0, 3) == rgb(0x7C00)
    assert binary_part(master_off, 0, 3) == rgb(0x001F)
  end

  defp solid_tile(color) do
    low = if (color &&& 0x01) == 0, do: 0, else: 0xFF
    high = if (color &&& 0x02) == 0, do: 0, else: 0xFF
    :binary.copy(<<low, high>>, 8)
  end

  defp tile_from_rows(rows) do
    for row <- rows, into: <<>> do
      low = Enum.reduce(row, 0, fn color, acc -> acc <<< 1 ||| (color &&& 1) end)
      high = Enum.reduce(row, 0, fn color, acc -> acc <<< 1 ||| (color >>> 1 &&& 1) end)
      <<low, high>>
    end
  end

  defp put_cgb_color(ppu, type, palette, color, rgb555) do
    {index_register, data_register} =
      case type do
        :bg -> {0xFF68, 0xFF69}
        :obj -> {0xFF6A, 0xFF6B}
      end

    index = palette * 8 + color * 2
    {ppu, []} = PPU.write(ppu, index_register, 0x80 ||| index)
    {ppu, []} = PPU.write(ppu, data_register, rgb555 &&& 0xFF)
    {ppu, []} = PPU.write(ppu, data_register, rgb555 >>> 8)
    ppu
  end

  defp rgb(rgb555) do
    expand = fn component -> component <<< 3 ||| component >>> 2 end

    <<expand.(rgb555 &&& 0x1F), expand.(rgb555 >>> 5 &&& 0x1F), expand.(rgb555 >>> 10 &&& 0x1F)>>
  end

  defp cgb_priority_frame(lcdc, bg_attrs, obj_attrs) do
    ppu =
      PPU.new(model: :cgb, lcdc: lcdc)
      |> PPU.load_vram(0x0010, solid_tile(1))
      |> PPU.load_vram(0x0020, solid_tile(2))
      |> PPU.load_vram(0x1800, :binary.copy(<<1>>, 0x400))
      |> PPU.load_vram(0x3800, :binary.copy(<<bg_attrs>>, 0x400))
      |> PPU.load_oam(0, <<16, 8, 2, obj_attrs>>)
      |> put_cgb_color(:bg, 1, 1, 0x7C00)
      |> put_cgb_color(:obj, 0, 2, 0x001F)

    {_ppu, [{:frame, 0, frame}, :vblank]} = PPU.tick(ppu, @frame_dots)
    frame
  end
end
