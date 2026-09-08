defmodule Beamicom.GB.PPU do
  @moduledoc """
  Pure DMG/CGB pixel-processing unit foundation.

  Time is measured in LCD dots. tick/2 jumps between mode and scanline
  boundaries rather than iterating dot by dot and returns interrupt/frame
  signals explicitly; the PPU never reaches into the CPU or bus.

  DMG frames contain one shade-index byte per pixel (0..3, lightest to darkest).
  CGB frames contain packed RGB24 pixels. CGB tile attributes, palette RAM, and
  object priority are resolved in a separate rendering path so the DMG hot path
  stays compact.

  This foundation uses the minimum 172-dot transfer period. FIFO stalls from
  fine scrolling, the window, and objects are not yet timing-visible.
  """

  import Bitwise

  @width 160
  @height 144
  @dots_per_line 456
  @lines_per_frame 154
  @frame_dots @dots_per_line * @lines_per_frame
  @vblank_start @dots_per_line * @height
  @oam_dots 80
  @transfer_end 252

  @blank_page :binary.copy(<<0>>, 256)
  @blank_vram List.duplicate(@blank_page, 64) |> List.to_tuple()
  @blank_oam :binary.copy(<<0>>, 160)
  @blank_frame :binary.copy(<<0>>, @width * @height)
  @blank_line :binary.copy(<<0>>, @width)
  @blank_cgb_frame :binary.copy(<<255>>, @width * @height * 3)
  @blank_color_ram :binary.copy(<<255>>, 64)
  @white_colors List.duplicate(<<255, 255, 255>>, 32) |> List.to_tuple()

  @expand5 for(component <- 0..31, do: component <<< 3 ||| component >>> 2)
           |> List.to_tuple()

  @bit_rows (for byte <- 0..255 do
               for bit <- 7..0//-1, into: <<>>, do: <<byte >>> bit &&& 1>>
             end)
            |> List.to_tuple()

  @signed_tile_offsets (for tile <- 0..255 do
                          signed = if tile < 128, do: tile, else: tile - 256
                          0x1000 + signed * 16
                        end)
                       |> List.to_tuple()

  @palette_luts (for palette <- 0..255 do
                   {palette &&& 0x03, palette >>> 2 &&& 0x03, palette >>> 4 &&& 0x03,
                    palette >>> 6 &&& 0x03}
                 end)
                |> List.to_tuple()

  # LCDC, writable STAT bits, SCY, SCX, LYC, BGP, OBP0, OBP1, WY, WX.
  @default_registers {0x91, 0x00, 0, 0, 0, 0xFC, 0xFF, 0xFF, 0, 0}

  @compile {:inline,
            lcdc: 1,
            register: 2,
            put_register: 3,
            ly: 1,
            dot: 1,
            mode: 1,
            vram_byte: 2,
            tile_pixel: 4}

  @enforce_keys [:vram, :oam]
  defstruct vram: @blank_vram,
            oam: @blank_oam,
            frame: @blank_frame,
            lines: [],
            registers: @default_registers,
            clock: 0,
            frame_number: 0,
            window_line: 0,
            stat_line: false,
            model: :dmg,
            vram_bank: 0,
            color_ram: {@blank_color_ram, @blank_color_ram},
            color_cache: {@white_colors, @white_colors},
            color_indexes: {0, 0}

  @type mode :: 0 | 1 | 2 | 3
  @type signal :: :vblank | :lcd_stat | {:frame, non_neg_integer(), binary()}

  @type t :: %__MODULE__{
          vram: tuple(),
          oam: binary(),
          frame: binary(),
          lines: [binary()],
          registers: tuple(),
          clock: non_neg_integer(),
          frame_number: non_neg_integer(),
          window_line: 0..144,
          stat_line: boolean(),
          model: :dmg | :cgb,
          vram_bank: 0 | 1,
          color_ram: {binary(), binary()},
          color_cache: {tuple(), tuple()},
          color_indexes: {byte(), byte()}
        }

  @doc "Creates a post-boot-shaped PPU with optional DMG register values."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    registers =
      @default_registers
      |> put_elem(0, Keyword.get(opts, :lcdc, elem(@default_registers, 0)) &&& 0xFF)
      |> put_elem(1, Keyword.get(opts, :stat, 0) &&& 0x78)
      |> put_elem(2, Keyword.get(opts, :scy, 0) &&& 0xFF)
      |> put_elem(3, Keyword.get(opts, :scx, 0) &&& 0xFF)
      |> put_elem(4, Keyword.get(opts, :lyc, 0) &&& 0xFF)
      |> put_elem(5, Keyword.get(opts, :bgp, 0xFC) &&& 0xFF)
      |> put_elem(6, Keyword.get(opts, :obp0, 0xFF) &&& 0xFF)
      |> put_elem(7, Keyword.get(opts, :obp1, 0xFF) &&& 0xFF)
      |> put_elem(8, Keyword.get(opts, :wy, 0) &&& 0xFF)
      |> put_elem(9, Keyword.get(opts, :wx, 0) &&& 0xFF)

    model = Keyword.get(opts, :model, :dmg)

    ppu = %__MODULE__{
      vram: @blank_vram,
      oam: @blank_oam,
      frame: initial_frame(model),
      registers: registers,
      model: model
    }

    %{ppu | stat_line: stat_condition?(ppu)}
  end

  @doc "Current LCD scanline, derived from the compact frame clock."
  @spec ly(t()) :: 0..153
  def ly(%__MODULE__{clock: clock}), do: div(clock, @dots_per_line)

  @doc "Current dot within the scanline."
  @spec dot(t()) :: 0..455
  def dot(%__MODULE__{clock: clock}), do: rem(clock, @dots_per_line)

  @doc "Current LCD mode: 0 HBlank, 1 VBlank, 2 OAM, or 3 transfer."
  @spec mode(t()) :: mode()
  def mode(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}})
      when (lcdc &&& 0x80) == 0,
      do: 0

  def mode(%__MODULE__{clock: clock}) when clock >= @vblank_start, do: 1

  def mode(%__MODULE__{clock: clock}) do
    case rem(clock, @dots_per_line) do
      dot when dot < @oam_dots -> 2
      dot when dot < @transfer_end -> 3
      _dot -> 0
    end
  end

  @doc "Most recently completed 160x144 framebuffer in pixel_format/1 format."
  @spec frame(t()) :: binary()
  def frame(%__MODULE__{frame: frame}), do: frame

  @doc "Returns :dmg_shade_index for DMG or :rgb24 for CGB frames."
  @spec pixel_format(t()) :: :dmg_shade_index | :rgb24
  def pixel_format(%__MODULE__{model: :dmg}), do: :dmg_shade_index
  def pixel_format(%__MODULE__{model: :cgb}), do: :rgb24

  @doc "Reads CPU-visible VRAM, OAM, or an LCD register."
  @spec read(t(), 0x8000..0x9FFF | 0xFE00..0xFE9F | 0xFF40..0xFF6B) :: byte()
  def read(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock}, address)
      when address in 0x8000..0x9FFF and (lcdc &&& 0x80) != 0 and
             div(clock, @dots_per_line) < @height and
             rem(clock, @dots_per_line) >= @oam_dots and
             rem(clock, @dots_per_line) < @transfer_end,
      do: 0xFF

  def read(%__MODULE__{model: :dmg, vram: vram}, address) when address in 0x8000..0x9FFF,
    do: vram_byte(vram, address - 0x8000)

  def read(%__MODULE__{vram: vram, vram_bank: bank}, address) when address in 0x8000..0x9FFF,
    do: vram_byte(vram, bank * 0x2000 + address - 0x8000)

  def read(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock}, address)
      when address in 0xFE00..0xFE9F and (lcdc &&& 0x80) != 0 and
             div(clock, @dots_per_line) < @height and
             rem(clock, @dots_per_line) < @transfer_end,
      do: 0xFF

  def read(%__MODULE__{oam: oam}, address) when address in 0xFE00..0xFE9F,
    do: :binary.at(oam, address - 0xFE00)

  def read(ppu, 0xFF40), do: register(ppu, 0)

  def read(ppu, 0xFF41) do
    coincidence = if ly(ppu) == register(ppu, 4), do: 0x04, else: 0
    0x80 ||| register(ppu, 1) ||| coincidence ||| mode(ppu)
  end

  def read(ppu, 0xFF42), do: register(ppu, 2)
  def read(ppu, 0xFF43), do: register(ppu, 3)
  def read(ppu, 0xFF44), do: ly(ppu)
  def read(ppu, 0xFF45), do: register(ppu, 4)
  def read(_ppu, 0xFF46), do: 0xFF
  def read(ppu, 0xFF47), do: register(ppu, 5)
  def read(ppu, 0xFF48), do: register(ppu, 6)
  def read(ppu, 0xFF49), do: register(ppu, 7)
  def read(ppu, 0xFF4A), do: register(ppu, 8)
  def read(ppu, 0xFF4B), do: register(ppu, 9)
  def read(%__MODULE__{model: :dmg}, 0xFF4F), do: 0xFF
  def read(%__MODULE__{model: :cgb, vram_bank: bank}, 0xFF4F), do: 0xFE ||| bank

  def read(%__MODULE__{model: :cgb, color_indexes: indexes}, 0xFF68), do: elem(indexes, 0)

  def read(%__MODULE__{model: :cgb} = ppu, 0xFF69),
    do: read_color_data(ppu, 0)

  def read(%__MODULE__{model: :cgb, color_indexes: indexes}, 0xFF6A), do: elem(indexes, 1)

  def read(%__MODULE__{model: :cgb} = ppu, 0xFF6B),
    do: read_color_data(ppu, 1)

  def read(%__MODULE__{model: :dmg}, address) when address in 0xFF68..0xFF6B, do: 0xFF

  @doc "Writes CPU-visible VRAM, OAM, or an LCD register and returns any STAT edge."
  @spec write(t(), 0x8000..0x9FFF | 0xFE00..0xFE9F | 0xFF40..0xFF6B, byte()) ::
          {t(), [signal()]}
  def write(
        %__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock} = ppu,
        address,
        value
      )
      when address in 0x8000..0x9FFF and value in 0..0xFF and (lcdc &&& 0x80) != 0 and
             div(clock, @dots_per_line) < @height and
             rem(clock, @dots_per_line) >= @oam_dots and
             rem(clock, @dots_per_line) < @transfer_end,
      do: {ppu, []}

  def write(%__MODULE__{model: :dmg, vram: vram} = ppu, address, value)
      when address in 0x8000..0x9FFF and value in 0..0xFF,
      do: {%{ppu | vram: put_vram_byte(vram, address - 0x8000, value)}, []}

  def write(%__MODULE__{vram: vram, vram_bank: bank} = ppu, address, value)
      when address in 0x8000..0x9FFF and value in 0..0xFF,
      do: {%{ppu | vram: put_vram_byte(vram, bank * 0x2000 + address - 0x8000, value)}, []}

  def write(
        %__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock} = ppu,
        address,
        value
      )
      when address in 0xFE00..0xFE9F and value in 0..0xFF and (lcdc &&& 0x80) != 0 and
             div(clock, @dots_per_line) < @height and
             rem(clock, @dots_per_line) < @transfer_end,
      do: {ppu, []}

  def write(%__MODULE__{oam: oam} = ppu, address, value)
      when address in 0xFE00..0xFE9F and value in 0..0xFF,
      do: {%{ppu | oam: put_binary_byte(oam, address - 0xFE00, value)}, []}

  def write(ppu, 0xFF40, value) when value in 0..0xFF do
    old_lcdc = lcdc(ppu)
    ppu = put_register(ppu, 0, value)

    ppu =
      cond do
        (value &&& 0x80) == 0 ->
          %{ppu | clock: 0, lines: [], window_line: 0, stat_line: false}

        (old_lcdc &&& 0x80) == 0 ->
          %{ppu | clock: 0, lines: [], window_line: 0, stat_line: false}

        true ->
          ppu
      end

    refresh_stat(ppu)
  end

  def write(ppu, 0xFF41, value) when value in 0..0xFF,
    do: ppu |> put_register(1, value &&& 0x78) |> refresh_stat()

  def write(ppu, 0xFF42, value) when value in 0..0xFF, do: {put_register(ppu, 2, value), []}
  def write(ppu, 0xFF43, value) when value in 0..0xFF, do: {put_register(ppu, 3, value), []}
  def write(ppu, 0xFF44, value) when value in 0..0xFF, do: {ppu, []}

  def write(ppu, 0xFF45, value) when value in 0..0xFF,
    do: ppu |> put_register(4, value) |> refresh_stat()

  def write(ppu, 0xFF46, value) when value in 0..0xFF, do: {ppu, []}
  def write(ppu, 0xFF47, value) when value in 0..0xFF, do: {put_register(ppu, 5, value), []}
  def write(ppu, 0xFF48, value) when value in 0..0xFF, do: {put_register(ppu, 6, value), []}
  def write(ppu, 0xFF49, value) when value in 0..0xFF, do: {put_register(ppu, 7, value), []}
  def write(ppu, 0xFF4A, value) when value in 0..0xFF, do: {put_register(ppu, 8, value), []}
  def write(ppu, 0xFF4B, value) when value in 0..0xFF, do: {put_register(ppu, 9, value), []}

  def write(%__MODULE__{model: :cgb} = ppu, 0xFF4F, value) when value in 0..0xFF,
    do: {%{ppu | vram_bank: value &&& 1}, []}

  def write(ppu, 0xFF4F, value) when value in 0..0xFF, do: {ppu, []}

  def write(%__MODULE__{model: :cgb, color_indexes: indexes} = ppu, 0xFF68, value)
      when value in 0..0xFF,
      do: {%{ppu | color_indexes: put_elem(indexes, 0, value &&& 0xBF)}, []}

  def write(%__MODULE__{model: :cgb} = ppu, 0xFF69, value) when value in 0..0xFF,
    do: {write_color_data(ppu, 0, value), []}

  def write(%__MODULE__{model: :cgb, color_indexes: indexes} = ppu, 0xFF6A, value)
      when value in 0..0xFF,
      do: {%{ppu | color_indexes: put_elem(indexes, 1, value &&& 0xBF)}, []}

  def write(%__MODULE__{model: :cgb} = ppu, 0xFF6B, value) when value in 0..0xFF,
    do: {write_color_data(ppu, 1, value), []}

  def write(%__MODULE__{model: :dmg} = ppu, address, value)
      when address in 0xFF68..0xFF6B and value in 0..0xFF,
      do: {ppu, []}

  @doc "Loads bytes directly into VRAM, bypassing CPU access restrictions."
  @spec load_vram(t(), 0..0x3FFF, binary()) :: t()
  def load_vram(%__MODULE__{} = ppu, offset, data)
      when offset in 0..0x3FFF and is_binary(data) and offset + byte_size(data) <= 0x4000 do
    %{ppu | vram: load_vram_bytes(ppu.vram, offset, data)}
  end

  @doc "Loads bytes directly into OAM, bypassing CPU access restrictions."
  @spec load_oam(t(), 0..0x9F, binary()) :: t()
  def load_oam(%__MODULE__{} = ppu, offset, data)
      when offset in 0..0x9F and is_binary(data) and offset + byte_size(data) <= 0xA0 do
    %{ppu | oam: replace_binary(ppu.oam, offset, data)}
  end

  @doc "Advances an exact number of LCD dots and returns chronological signals."
  @spec tick(t(), non_neg_integer()) :: {t(), [signal()]}
  def tick(%__MODULE__{} = ppu, 0), do: {ppu, []}

  # LCD-off time does not advance and cannot produce mode/VBlank signals.
  def tick(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu, dots)
      when dots > 0 and (lcdc &&& 0x80) == 0,
      do: {ppu, []}

  def tick(%__MODULE__{} = ppu, dots) when dots > 0, do: advance(ppu, dots, [])

  defp advance(ppu, 0, signals), do: {ppu, :lists.reverse(signals)}

  defp advance(ppu, dots, signals) do
    {distance, event} = next_event(ppu.clock)

    if dots < distance do
      {%{ppu | clock: ppu.clock + dots}, :lists.reverse(signals)}
    else
      ppu = %{ppu | clock: ppu.clock + distance}
      {ppu, emitted} = handle_event(ppu, event)
      signals = Enum.reduce(emitted, signals, fn signal, acc -> [signal | acc] end)
      advance(ppu, dots - distance, signals)
    end
  end

  defp next_event(clock) when clock >= @vblank_start do
    dot = rem(clock, @dots_per_line)
    {@dots_per_line - dot, :line_end}
  end

  defp next_event(clock) do
    dot = rem(clock, @dots_per_line)

    cond do
      dot < @oam_dots -> {@oam_dots - dot, :transfer}
      dot < @transfer_end -> {@transfer_end - dot, :hblank}
      true -> {@dots_per_line - dot, :line_end}
    end
  end

  defp handle_event(ppu, :transfer), do: refresh_stat(ppu)

  defp handle_event(ppu, :hblank) do
    ppu = render_line(ppu)
    refresh_stat(ppu)
  end

  defp handle_event(%__MODULE__{clock: @frame_dots} = ppu, :line_end) do
    ppu = %{ppu | clock: 0, lines: [], window_line: 0}
    refresh_stat(ppu)
  end

  defp handle_event(%__MODULE__{clock: @vblank_start} = ppu, :line_end) do
    frame = ppu.lines |> :lists.reverse() |> IO.iodata_to_binary()
    number = ppu.frame_number
    ppu = %{ppu | frame: frame, lines: [], frame_number: number + 1}
    {ppu, stat} = refresh_stat(ppu)
    {ppu, [{:frame, number, frame}, :vblank | stat]}
  end

  defp handle_event(ppu, :line_end), do: refresh_stat(ppu)

  # CGB composition remains separate from DMG so color metadata and RGB output
  # add no work to the common DMG path.
  defp render_line(%__MODULE__{model: :cgb, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu)
       when (lcdc &&& 0x02) == 0 do
    {colors, ppu} = cgb_background_line(ppu, ly(ppu), lcdc)
    line = apply_cgb_palette(colors, elem(ppu.color_cache, 0))
    %{ppu | lines: [line | ppu.lines]}
  end

  defp render_line(%__MODULE__{model: :cgb, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu) do
    line_number = ly(ppu)
    {colors, ppu} = cgb_background_line(ppu, line_number, lcdc)
    height = if (lcdc &&& 0x04) == 0, do: 8, else: 16
    sprites = select_cgb_sprites(ppu.oam, line_number, height, 0, 0, [])
    {bg_colors, obj_colors} = ppu.color_cache

    line =
      compose_cgb_sprites(
        colors,
        sprites,
        ppu.vram,
        line_number,
        height,
        lcdc,
        bg_colors,
        obj_colors
      )

    %{ppu | lines: [line | ppu.lines]}
  end

  # Both layers disabled is common for blanking and avoids all tile/OAM work.
  defp render_line(%__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu)
       when (lcdc &&& 0x03) == 0,
       do: %{ppu | lines: [@blank_line | ppu.lines]}

  # Object-disabled games take the background-only path without OAM scanning.
  defp render_line(%__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, bgp, _, _, _, _}} = ppu)
       when (lcdc &&& 0x02) == 0 do
    {colors, ppu} = background_line(ppu, ly(ppu), lcdc)
    line = apply_palette(colors, bgp)
    %{ppu | lines: [line | ppu.lines]}
  end

  defp render_line(
         %__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, bgp, obp0, obp1, _, _}} = ppu
       ) do
    line_number = ly(ppu)
    {colors, ppu} = background_line(ppu, line_number, lcdc)
    height = if (lcdc &&& 0x04) == 0, do: 8, else: 16
    sprites = select_sprites(ppu.oam, line_number, height, 0, 0, [])
    line = compose_sprites(colors, sprites, ppu.vram, line_number, height, bgp, obp0, obp1)
    %{ppu | lines: [line | ppu.lines]}
  end

  # Each CGB background byte packs color in bits 0..1, palette in bits 2..4,
  # and the tile priority attribute in bit 5.
  defp cgb_background_line(
         %__MODULE__{registers: {_, _, scy, scx, _, _, _, _, _, _}} = ppu,
         line,
         lcdc
       )
       when (lcdc &&& 0x20) == 0 do
    {cgb_background_tiles(ppu.vram, line + scy &&& 0xFF, scx, lcdc), ppu}
  end

  defp cgb_background_line(
         %__MODULE__{registers: {_, _, scy, scx, _, _, _, _, wy, wx}} = ppu,
         line,
         lcdc
       ) do
    background = cgb_background_tiles(ppu.vram, line + scy &&& 0xFF, scx, lcdc)
    window_x = wx - 7

    if line >= wy and window_x < @width do
      window = cgb_window_tiles(ppu.vram, ppu.window_line, lcdc)
      visible_x = max(window_x, 0)
      hidden = max(-window_x, 0)
      count = @width - visible_x

      colors =
        binary_part(background, 0, visible_x) <>
          binary_part(window, hidden, count)

      {colors, %{ppu | window_line: ppu.window_line + 1}}
    else
      {background, ppu}
    end
  end

  defp cgb_background_tiles(vram, y, scx, lcdc) do
    map = if (lcdc &&& 0x08) == 0, do: 0x1800, else: 0x1C00
    tile_y = y >>> 3
    row = y &&& 0x07
    first_tile = scx >>> 3

    tiles =
      for column <- 0..20 do
        tile_x = first_tile + column &&& 0x1F
        map_offset = map + tile_y * 32 + tile_x
        tile = vram_byte(vram, map_offset)
        attrs = vram_byte(vram, 0x2000 + map_offset)
        cgb_tile_row(vram, tile, row, lcdc, attrs)
      end

    tiles |> IO.iodata_to_binary() |> binary_part(scx &&& 0x07, @width)
  end

  defp cgb_window_tiles(vram, y, lcdc) do
    map = if (lcdc &&& 0x40) == 0, do: 0x1800, else: 0x1C00
    tile_y = y >>> 3 &&& 0x1F
    row = y &&& 0x07

    for column <- 0..20, into: <<>> do
      map_offset = map + tile_y * 32 + column
      tile = vram_byte(vram, map_offset)
      attrs = vram_byte(vram, 0x2000 + map_offset)
      cgb_tile_row(vram, tile, row, lcdc, attrs)
    end
  end

  defp cgb_tile_row(vram, tile, row, lcdc, attrs) do
    row = if (attrs &&& 0x40) == 0, do: row, else: 7 - row

    offset =
      if (lcdc &&& 0x10) == 0,
        do: elem(@signed_tile_offsets, tile),
        else: tile * 16

    offset = if (attrs &&& 0x08) == 0, do: offset, else: offset + 0x2000
    low = vram_byte(vram, offset + row * 2)
    high = vram_byte(vram, offset + row * 2 + 1)
    colors = combine_planes(elem(@bit_rows, low), elem(@bit_rows, high))
    colors = if (attrs &&& 0x20) == 0, do: colors, else: reverse_row(colors)
    metadata = (attrs &&& 0x07) <<< 2 ||| (attrs &&& 0x80) >>> 2
    for <<color <- colors>>, into: <<>>, do: <<color ||| metadata>>
  end

  defp reverse_row(<<a, b, c, d, e, f, g, h>>), do: <<h, g, f, e, d, c, b, a>>

  defp background_line(ppu, _line, lcdc) when (lcdc &&& 0x01) == 0,
    do: {@blank_line, ppu}

  # Window-disabled head avoids all WX/WY/window-line work.
  defp background_line(
         %__MODULE__{registers: {_, _, scy, scx, _, _, _, _, _, _}} = ppu,
         line,
         lcdc
       )
       when (lcdc &&& 0x20) == 0 do
    {background_tiles(ppu.vram, line + scy &&& 0xFF, scx, lcdc), ppu}
  end

  defp background_line(
         %__MODULE__{registers: {_, _, scy, scx, _, _, _, _, wy, wx}} = ppu,
         line,
         lcdc
       ) do
    background = background_tiles(ppu.vram, line + scy &&& 0xFF, scx, lcdc)
    window_x = wx - 7

    if line >= wy and window_x < @width do
      window = window_tiles(ppu.vram, ppu.window_line, lcdc)
      visible_x = max(window_x, 0)
      hidden = max(-window_x, 0)
      count = @width - visible_x

      colors =
        binary_part(background, 0, visible_x) <>
          binary_part(window, hidden, count)

      {colors, %{ppu | window_line: ppu.window_line + 1}}
    else
      {background, ppu}
    end
  end

  defp background_tiles(vram, y, scx, lcdc) do
    map = if (lcdc &&& 0x08) == 0, do: 0x1800, else: 0x1C00
    tile_y = y >>> 3
    row = y &&& 0x07
    first_tile = scx >>> 3

    tiles =
      for column <- 0..20 do
        tile_x = first_tile + column &&& 0x1F
        tile = vram_byte(vram, map + tile_y * 32 + tile_x)
        tile_row(vram, tile, row, lcdc)
      end

    tiles |> IO.iodata_to_binary() |> binary_part(scx &&& 0x07, @width)
  end

  defp window_tiles(vram, y, lcdc) do
    map = if (lcdc &&& 0x40) == 0, do: 0x1800, else: 0x1C00
    tile_y = y >>> 3 &&& 0x1F
    row = y &&& 0x07

    for column <- 0..20, into: <<>> do
      tile = vram_byte(vram, map + tile_y * 32 + column)
      tile_row(vram, tile, row, lcdc)
    end
  end

  defp tile_row(vram, tile, row, lcdc) do
    offset =
      if (lcdc &&& 0x10) == 0,
        do: elem(@signed_tile_offsets, tile),
        else: tile * 16

    low = vram_byte(vram, offset + row * 2)
    high = vram_byte(vram, offset + row * 2 + 1)
    combine_planes(elem(@bit_rows, low), elem(@bit_rows, high))
  end

  defp combine_planes(
         <<l0, l1, l2, l3, l4, l5, l6, l7>>,
         <<h0, h1, h2, h3, h4, h5, h6, h7>>
       ),
       do:
         <<l0 ||| h0 <<< 1, l1 ||| h1 <<< 1, l2 ||| h2 <<< 1, l3 ||| h3 <<< 1, l4 ||| h4 <<< 1,
           l5 ||| h5 <<< 1, l6 ||| h6 <<< 1, l7 ||| h7 <<< 1>>

  defp apply_palette(colors, palette) do
    lookup = elem(@palette_luts, palette)
    for <<color <- colors>>, into: <<>>, do: <<elem(lookup, color)>>
  end

  defp apply_cgb_palette(colors, palette),
    do: apply_cgb_palette(colors, palette, []) |> :lists.reverse() |> IO.iodata_to_binary()

  defp apply_cgb_palette(<<>>, _palette, acc), do: acc

  defp apply_cgb_palette(<<metadata, rest::binary>>, palette, acc) do
    index = (metadata >>> 2 &&& 0x07) * 4 + (metadata &&& 0x03)
    apply_cgb_palette(rest, palette, [elem(palette, index) | acc])
  end

  defp select_sprites(_oam, _line, _height, 40, _count, sprites),
    do: sort_sprites(sprites)

  defp select_sprites(_oam, _line, _height, _index, 10, sprites),
    do: sort_sprites(sprites)

  defp select_sprites(oam, line, height, index, count, sprites) do
    offset = index * 4
    y = :binary.at(oam, offset) - 16

    if line >= y and line < y + height do
      sprite =
        {:binary.at(oam, offset + 1) - 8, y, :binary.at(oam, offset + 2),
         :binary.at(oam, offset + 3), index}

      select_sprites(oam, line, height, index + 1, count + 1, [sprite | sprites])
    else
      select_sprites(oam, line, height, index + 1, count, sprites)
    end
  end

  defp sort_sprites(sprites),
    do: Enum.sort_by(sprites, fn {x, _y, _tile, _attrs, index} -> {x, index} end)

  defp select_cgb_sprites(_oam, _line, _height, 40, _count, sprites),
    do: :lists.reverse(sprites)

  defp select_cgb_sprites(_oam, _line, _height, _index, 10, sprites),
    do: :lists.reverse(sprites)

  defp select_cgb_sprites(oam, line, height, index, count, sprites) do
    offset = index * 4
    y = :binary.at(oam, offset) - 16

    if line >= y and line < y + height do
      sprite =
        {:binary.at(oam, offset + 1) - 8, y, :binary.at(oam, offset + 2),
         :binary.at(oam, offset + 3), index}

      select_cgb_sprites(oam, line, height, index + 1, count + 1, [sprite | sprites])
    else
      select_cgb_sprites(oam, line, height, index + 1, count, sprites)
    end
  end

  defp compose_sprites(colors, sprites, vram, line, height, bgp, obp0, obp1) do
    bg = elem(@palette_luts, bgp)
    obj0 = elem(@palette_luts, obp0)
    obj1 = elem(@palette_luts, obp1)
    compose_pixel(0, colors, sprites, vram, line, height, bg, obj0, obj1, [])
  end

  defp compose_pixel(@width, _colors, _sprites, _vram, _line, _height, _bg, _obj0, _obj1, acc),
    do: acc |> :lists.reverse() |> :erlang.list_to_binary()

  defp compose_pixel(x, colors, sprites, vram, line, height, bg, obj0, obj1, acc) do
    bg_color = :binary.at(colors, x)

    shade =
      case sprite_pixel(sprites, x, line, height, vram) do
        :transparent ->
          elem(bg, bg_color)

        {_color, attrs} when (attrs &&& 0x80) != 0 and bg_color != 0 ->
          elem(bg, bg_color)

        {color, attrs} ->
          palette = if (attrs &&& 0x10) == 0, do: obj0, else: obj1
          elem(palette, color)
      end

    compose_pixel(x + 1, colors, sprites, vram, line, height, bg, obj0, obj1, [shade | acc])
  end

  defp sprite_pixel([], _x, _line, _height, _vram), do: :transparent

  defp sprite_pixel([{left, _top, _tile, _attrs, _index} | sprites], x, line, height, vram)
       when x < left or x >= left + 8,
       do: sprite_pixel(sprites, x, line, height, vram)

  defp sprite_pixel([{left, top, tile, attrs, _index} | sprites], x, line, height, vram) do
    source_y = line - top
    source_y = if (attrs &&& 0x40) == 0, do: source_y, else: height - 1 - source_y
    tile = if height == 8, do: tile, else: (tile &&& 0xFE) + (source_y >>> 3)
    source_x = x - left
    source_x = if (attrs &&& 0x20) == 0, do: source_x, else: 7 - source_x
    color = tile_pixel(vram, tile, source_y &&& 0x07, source_x)

    if color == 0,
      do: sprite_pixel(sprites, x, line, height, vram),
      else: {color, attrs}
  end

  defp tile_pixel(vram, tile, row, x) do
    offset = tile * 16 + row * 2
    bit = 7 - x

    (vram_byte(vram, offset) >>> bit &&& 1) |||
      (vram_byte(vram, offset + 1) >>> bit &&& 1) <<< 1
  end

  defp compose_cgb_sprites(colors, sprites, vram, line, height, lcdc, bg, obj) do
    compose_cgb_pixel(0, colors, sprites, vram, line, height, lcdc, bg, obj, [])
  end

  defp compose_cgb_pixel(@width, _colors, _sprites, _vram, _line, _height, _lcdc, _bg, _obj, acc),
    do: acc |> :lists.reverse() |> IO.iodata_to_binary()

  defp compose_cgb_pixel(x, colors, sprites, vram, line, height, lcdc, bg, obj, acc) do
    metadata = :binary.at(colors, x)
    bg_color = metadata &&& 0x03
    bg_index = (metadata >>> 2 &&& 0x07) * 4 + bg_color

    rgb =
      case cgb_sprite_pixel(sprites, x, line, height, vram) do
        :transparent ->
          elem(bg, bg_index)

        {_color, _attrs}
        when bg_color != 0 and (lcdc &&& 0x01) != 0 and (metadata &&& 0x20) != 0 ->
          elem(bg, bg_index)

        {_color, attrs} when bg_color != 0 and (lcdc &&& 0x01) != 0 and (attrs &&& 0x80) != 0 ->
          elem(bg, bg_index)

        {color, attrs} ->
          elem(obj, (attrs &&& 0x07) * 4 + color)
      end

    compose_cgb_pixel(x + 1, colors, sprites, vram, line, height, lcdc, bg, obj, [rgb | acc])
  end

  defp cgb_sprite_pixel([], _x, _line, _height, _vram), do: :transparent

  defp cgb_sprite_pixel([{left, _top, _tile, _attrs, _index} | sprites], x, line, height, vram)
       when x < left or x >= left + 8,
       do: cgb_sprite_pixel(sprites, x, line, height, vram)

  defp cgb_sprite_pixel([{left, top, tile, attrs, _index} | sprites], x, line, height, vram) do
    source_y = line - top
    source_y = if (attrs &&& 0x40) == 0, do: source_y, else: height - 1 - source_y
    tile = if height == 8, do: tile, else: (tile &&& 0xFE) + (source_y >>> 3)
    source_x = x - left
    source_x = if (attrs &&& 0x20) == 0, do: source_x, else: 7 - source_x
    bank_offset = if (attrs &&& 0x08) == 0, do: 0, else: 0x2000
    color = tile_pixel(vram, tile, source_y &&& 0x07, source_x, bank_offset)

    if color == 0,
      do: cgb_sprite_pixel(sprites, x, line, height, vram),
      else: {color, attrs}
  end

  defp tile_pixel(vram, tile, row, x, bank_offset) do
    offset = bank_offset + tile * 16 + row * 2
    bit = 7 - x

    (vram_byte(vram, offset) >>> bit &&& 1) |||
      (vram_byte(vram, offset + 1) >>> bit &&& 1) <<< 1
  end

  defp refresh_stat(ppu) do
    active = stat_condition?(ppu)
    signal = if active and not ppu.stat_line, do: [:lcd_stat], else: []
    {%{ppu | stat_line: active}, signal}
  end

  defp stat_condition?(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}})
       when (lcdc &&& 0x80) == 0,
       do: false

  defp stat_condition?(ppu) do
    select = register(ppu, 1)
    coincidence = (select &&& 0x40) != 0 and ly(ppu) == register(ppu, 4)

    mode_selected =
      case mode(ppu) do
        0 -> (select &&& 0x08) != 0
        1 -> (select &&& 0x10) != 0
        2 -> (select &&& 0x20) != 0
        3 -> false
      end

    coincidence or mode_selected
  end

  defp read_color_data(
         %__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock},
         _palette
       )
       when (lcdc &&& 0x80) != 0 and div(clock, @dots_per_line) < @height and
              rem(clock, @dots_per_line) >= @oam_dots and
              rem(clock, @dots_per_line) < @transfer_end,
       do: 0xFF

  defp read_color_data(%__MODULE__{color_ram: ram, color_indexes: indexes}, palette) do
    :binary.at(elem(ram, palette), elem(indexes, palette) &&& 0x3F)
  end

  # CGB hardware still advances an auto-incrementing palette index when a
  # mode-3 data write is blocked.
  defp write_color_data(
         %__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}, clock: clock} = ppu,
         palette,
         _value
       )
       when (lcdc &&& 0x80) != 0 and div(clock, @dots_per_line) < @height and
              rem(clock, @dots_per_line) >= @oam_dots and
              rem(clock, @dots_per_line) < @transfer_end,
       do: increment_color_index(ppu, palette)

  defp write_color_data(
         %__MODULE__{color_ram: ram, color_cache: cache, color_indexes: indexes} = ppu,
         palette,
         value
       ) do
    index = elem(indexes, palette)
    offset = index &&& 0x3F
    palette_ram = put_binary_byte(elem(ram, palette), offset, value)
    color_offset = offset &&& 0x3E
    low = :binary.at(palette_ram, color_offset)
    high = :binary.at(palette_ram, color_offset + 1)
    color = low ||| (high &&& 0x7F) <<< 8

    rgb =
      <<elem(@expand5, color &&& 0x1F), elem(@expand5, color >>> 5 &&& 0x1F),
        elem(@expand5, color >>> 10 &&& 0x1F)>>

    palette_cache = put_elem(elem(cache, palette), color_offset >>> 1, rgb)

    ppu = %{
      ppu
      | color_ram: put_elem(ram, palette, palette_ram),
        color_cache: put_elem(cache, palette, palette_cache)
    }

    increment_color_index(ppu, palette)
  end

  defp increment_color_index(%__MODULE__{color_indexes: indexes} = ppu, palette) do
    index = elem(indexes, palette)

    next =
      if (index &&& 0x80) == 0,
        do: index,
        else: 0x80 ||| (index + 1 &&& 0x3F)

    %{ppu | color_indexes: put_elem(indexes, palette, next)}
  end

  defp initial_frame(:dmg), do: @blank_frame
  defp initial_frame(:cgb), do: @blank_cgb_frame

  defp lcdc(%__MODULE__{registers: registers}), do: elem(registers, 0)
  defp register(%__MODULE__{registers: registers}, index), do: elem(registers, index)

  defp put_register(%__MODULE__{registers: registers} = ppu, index, value),
    do: %{ppu | registers: put_elem(registers, index, value)}

  defp vram_byte(vram, offset),
    do: :binary.at(elem(vram, offset >>> 8), offset &&& 0xFF)

  defp put_vram_byte(vram, offset, value) do
    page_index = offset >>> 8
    page = elem(vram, page_index)
    put_elem(vram, page_index, put_binary_byte(page, offset &&& 0xFF, value))
  end

  defp put_binary_byte(binary, offset, value) do
    <<prefix::binary-size(^offset), _old, suffix::binary>> = binary
    prefix <> <<value>> <> suffix
  end

  defp replace_binary(binary, offset, data) do
    size = byte_size(data)
    <<prefix::binary-size(^offset), _old::binary-size(^size), suffix::binary>> = binary
    prefix <> data <> suffix
  end

  defp load_vram_bytes(vram, _offset, <<>>), do: vram

  defp load_vram_bytes(vram, offset, data) do
    page_index = offset >>> 8
    page_offset = offset &&& 0xFF
    count = min(byte_size(data), 256 - page_offset)
    <<chunk::binary-size(^count), rest::binary>> = data
    page = elem(vram, page_index)
    vram = put_elem(vram, page_index, replace_binary(page, page_offset, chunk))
    load_vram_bytes(vram, offset + count, rest)
  end
end
