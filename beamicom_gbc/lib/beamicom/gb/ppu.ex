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

  Mode 3 includes the documented FIFO penalties from fine scrolling, the
  window, and objects. Pixel composition is still scanline-granular, so
  mid-scanline register effects are not timing-visible.
  """

  import Bitwise

  alias Beamicom.GB.DeferredFrame

  @compile {:no_warn_undefined, Beamicom.GB.Nx.PPURenderer}
  @renderer Application.compile_env(:beamicom_gbc, :ppu_renderer, :native)
  @dynamic_renderers Application.compile_env(:beamicom_gbc, :allow_runtime_renderers, false)

  @width 160
  @height 144
  @dots_per_line 456
  @lines_per_frame 154
  @frame_dots @dots_per_line * @lines_per_frame
  @vblank_start @dots_per_line * @height
  # CGB LCD retention outlasts one visible scanout by 3,640 double-speed ticks.
  @cgb_frame_repeat_dots 1_820
  @oam_dots 80
  @minimum_transfer_end 252

  @blank_page :binary.copy(<<0>>, 256)
  @blank_vram List.duplicate(@blank_page, 64) |> List.to_tuple()
  @blank_oam :binary.copy(<<0>>, 160)
  @blank_frame :binary.copy(<<0>>, @width * @height)
  @blank_cgb_frame :binary.copy(<<255>>, @width * @height * 3)
  @blank_color_ram :binary.copy(<<255>>, 64)
  @white_colors List.duplicate(<<255, 255, 255>>, 32) |> List.to_tuple()

  @expand5 for(component <- 0..31, do: component <<< 3 ||| component >>> 2)
           |> List.to_tuple()

  if @renderer == :native or @dynamic_renderers do
    @blank_line :binary.copy(<<0>>, @width)

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
  end

  # LCDC, writable STAT bits, SCY, SCX, LYC, BGP, OBP0, OBP1, WY, WX.
  @default_registers {0x91, 0x00, 0, 0, 0, 0xFC, 0xFF, 0xFF, 0, 0}

  @compile {:inline, lcdc: 1, register: 2, put_register: 3, ly: 1, dot: 1, mode: 1, vram_byte: 2}

  if @renderer == :native or @dynamic_renderers do
    @compile {:inline, tile_pixel: 4, cgb_pixel_no_priority: 4, cgb_pixel_with_priority: 4}
  end

  @enforce_keys [:vram, :oam]
  defstruct vram: @blank_vram,
            oam: @blank_oam,
            frame: @blank_frame,
            lines: [],
            registers: @default_registers,
            clock: 0,
            transfer_end: @minimum_transfer_end,
            frame_number: 0,
            lcd_frame_state: :steady,
            lcd_off_dots: 0,
            window_line: 0,
            stat_line: false,
            model: :dmg,
            vram_bank: 0,
            color_ram: {@blank_color_ram, @blank_color_ram},
            color_cache: {@white_colors, @white_colors},
            color_indexes: {0, 0},
            renderer: @renderer,
            renderer_state: nil,
            renderer_snapshot: nil,
            renderer_events: []

  @type mode :: 0 | 1 | 2 | 3
  @type frame :: binary() | DeferredFrame.t()
  @type signal :: :vblank | :lcd_stat | {:frame, non_neg_integer(), frame()}

  @type t :: %__MODULE__{
          vram: tuple(),
          oam: binary(),
          frame: binary(),
          lines: [binary()],
          registers: tuple(),
          clock: non_neg_integer(),
          transfer_end: 252..369,
          frame_number: non_neg_integer(),
          lcd_frame_state: :steady | :suppress | :suppressed,
          lcd_off_dots: 0..1821,
          window_line: 0..144,
          stat_line: boolean(),
          model: :dmg | :cgb,
          vram_bank: 0 | 1,
          color_ram: {binary(), binary()},
          color_cache: {tuple(), tuple()},
          color_indexes: {byte(), byte()},
          renderer: :native | module(),
          renderer_state: term(),
          renderer_snapshot: nil | {tuple(), binary(), {binary(), binary()}},
          renderer_events: [{0..143, 0..2, non_neg_integer(), byte()}]
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

    renderer_state = if @renderer == :native, do: nil, else: prepare_renderer(@renderer, model)

    ppu = %__MODULE__{
      vram: @blank_vram,
      oam: @blank_oam,
      frame: initial_frame(model),
      registers: registers,
      model: model,
      renderer: @renderer,
      renderer_state: renderer_state
    }

    ppu = reset_renderer_capture(ppu)
    %{ppu | stat_line: stat_condition?(ppu)}
  end

  @doc "Selects native scanline composition or an optional frame renderer."
  @spec set_renderer(t(), :native | :nx | module()) :: t()
  def set_renderer(ppu, :native),
    do: %{
      ppu
      | renderer: :native,
        renderer_state: nil,
        lines: [],
        renderer_snapshot: nil,
        renderer_events: []
    }

  def set_renderer(ppu, :nx), do: set_renderer(ppu, Beamicom.GB.Nx.PPURenderer)

  def set_renderer(ppu, renderer) when is_atom(renderer) do
    ppu = %{
      ppu
      | renderer: renderer,
        renderer_state: prepare_renderer(renderer, ppu.model),
        lines: []
    }

    reset_renderer_capture(ppu)
  end

  defp prepare_renderer(renderer, model) do
    unless Code.ensure_loaded?(renderer) and function_exported?(renderer, :prepare, 1),
      do: raise("invalid Game Boy PPU renderer: #{inspect(renderer)}")

    apply(renderer, :prepare, [model])
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

  def mode(%__MODULE__{clock: clock} = ppu) do
    case rem(clock, @dots_per_line) do
      dot when dot < @oam_dots -> 2
      dot -> if dot < hblank_dot(ppu), do: 3, else: 0
    end
  end

  @doc false
  @spec hblank_dot(t()) :: 252..369
  def hblank_dot(%__MODULE__{} = ppu) do
    if dot(ppu) >= @oam_dots,
      do: ppu.transfer_end,
      else: hblank_dot(ppu, ly(ppu))
  end

  @doc false
  @spec hblank_dot(t(), 0..153) :: 252..369
  def hblank_dot(%__MODULE__{} = ppu, line) when line in 0..153 do
    min(@minimum_transfer_end + mode3_penalty(ppu, line), 369)
  end

  @doc "Most recently completed 160x144 framebuffer in pixel_format/1 format."
  @spec frame(t()) :: frame()
  def frame(%__MODULE__{frame: frame}), do: frame

  @doc "Renderer selected when this core build was compiled."
  def configured_renderer, do: @renderer

  @doc "Returns :dmg_shade_index for DMG or :rgb24 for CGB frames."
  @spec pixel_format(t()) :: :dmg_shade_index | :rgb24
  def pixel_format(%__MODULE__{model: :dmg}), do: :dmg_shade_index
  def pixel_format(%__MODULE__{model: :cgb}), do: :rgb24

  @doc "Reads CPU-visible VRAM, OAM, or an LCD register."
  @spec read(t(), 0x8000..0x9FFF | 0xFE00..0xFE9F | 0xFF40..0xFF6B) :: byte()
  def read(%__MODULE__{} = ppu, address) when address in 0x8000..0x9FFF do
    cond do
      mode(ppu) == 3 -> 0xFF
      ppu.model == :dmg -> vram_byte(ppu.vram, address - 0x8000)
      true -> vram_byte(ppu.vram, ppu.vram_bank * 0x2000 + address - 0x8000)
    end
  end

  def read(%__MODULE__{oam: oam} = ppu, address) when address in 0xFE00..0xFE9F do
    if mode(ppu) in [2, 3], do: 0xFF, else: :binary.at(oam, address - 0xFE00)
  end

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
  def write(%__MODULE__{} = ppu, address, value)
      when address in 0x8000..0x9FFF and value in 0..0xFF do
    if mode(ppu) == 3 do
      {ppu, []}
    else
      offset =
        if ppu.model == :dmg,
          do: address - 0x8000,
          else: ppu.vram_bank * 0x2000 + address - 0x8000

      updated = %{ppu | vram: put_vram_byte(ppu.vram, offset, value)}
      {put_renderer_byte(ppu, :vram, offset, value, updated), []}
    end
  end

  def write(%__MODULE__{} = ppu, address, value)
      when address in 0xFE00..0xFE9F and value in 0..0xFF do
    if mode(ppu) in [2, 3] do
      {ppu, []}
    else
      offset = address - 0xFE00
      updated = %{ppu | oam: put_binary_byte(ppu.oam, offset, value)}
      {put_renderer_byte(ppu, :oam, offset, value, updated), []}
    end
  end

  def write(ppu, 0xFF40, value) when value in 0..0xFF do
    old_lcdc = lcdc(ppu)
    ppu = put_register(ppu, 0, value)

    ppu =
      cond do
        (value &&& 0x80) == 0 ->
          %{
            ppu
            | clock: 0,
              transfer_end: @minimum_transfer_end,
              lines: [],
              lcd_off_dots: lcd_off_dots(ppu, old_lcdc),
              window_line: 0,
              stat_line: false
          }
          |> reset_renderer_capture()

        (old_lcdc &&& 0x80) == 0 ->
          %{
            ppu
            | clock: 0,
              transfer_end: @minimum_transfer_end,
              lines: [],
              lcd_frame_state: lcd_startup_state(ppu),
              window_line: 0,
              stat_line: false
          }
          |> reset_renderer_capture()

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

  def write(%__MODULE__{model: :cgb, color_indexes: indexes} = ppu, 0xFF69, value)
      when value in 0..0xFF do
    updated = write_color_data(ppu, 0, value)
    {put_renderer_byte(ppu, :palette, elem(indexes, 0) &&& 0x3F, value, updated), []}
  end

  def write(%__MODULE__{model: :cgb, color_indexes: indexes} = ppu, 0xFF6A, value)
      when value in 0..0xFF,
      do: {%{ppu | color_indexes: put_elem(indexes, 1, value &&& 0xBF)}, []}

  def write(%__MODULE__{model: :cgb, color_indexes: indexes} = ppu, 0xFF6B, value)
      when value in 0..0xFF do
    updated = write_color_data(ppu, 1, value)
    {put_renderer_byte(ppu, :palette, 64 + (elem(indexes, 1) &&& 0x3F), value, updated), []}
  end

  def write(%__MODULE__{model: :dmg} = ppu, address, value)
      when address in 0xFF68..0xFF6B and value in 0..0xFF,
      do: {ppu, []}

  @doc "Loads bytes directly into VRAM, bypassing CPU access restrictions."
  @spec load_vram(t(), 0..0x3FFF, binary()) :: t()
  def load_vram(%__MODULE__{} = ppu, offset, data)
      when offset in 0..0x3FFF and is_binary(data) and offset + byte_size(data) <= 0x4000 do
    updated = %{ppu | vram: load_vram_bytes(ppu.vram, offset, data)}
    put_renderer_bytes(ppu, updated, :vram, offset, data)
  end

  @doc "Loads bytes directly into OAM, bypassing CPU access restrictions."
  @spec load_oam(t(), 0..0x9F, binary()) :: t()
  def load_oam(%__MODULE__{} = ppu, offset, data)
      when offset in 0..0x9F and is_binary(data) and offset + byte_size(data) <= 0xA0 do
    updated = %{ppu | oam: replace_binary(ppu.oam, offset, data)}
    put_renderer_bytes(ppu, updated, :oam, offset, data)
  end

  @doc "Advances an exact number of LCD dots and returns chronological signals."
  @spec tick(t(), non_neg_integer()) :: {t(), [signal()]}
  def tick(%__MODULE__{} = ppu, 0), do: {ppu, []}

  # LCD raster time stops and cannot produce mode/VBlank signals while the
  # panel-retention timer continues to elapse.
  def tick(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu, dots)
      when dots > 0 and (lcdc &&& 0x80) == 0 do
    elapsed = min(ppu.lcd_off_dots + dots, @cgb_frame_repeat_dots + 1)
    {%{ppu | lcd_off_dots: elapsed}, []}
  end

  # CPU memory cycles almost always remain within the current LCD mode. Keep
  # those tiny advances out of the recursive boundary/event machinery; exact
  # boundary hits and multi-boundary batches continue through advance/3.
  def tick(%__MODULE__{clock: clock} = ppu, dots)
      when dots > 0 and clock < @vblank_start and rem(clock, @dots_per_line) < @oam_dots and
             rem(clock, @dots_per_line) + dots < @oam_dots,
      do: {%{ppu | clock: clock + dots}, []}

  def tick(%__MODULE__{clock: clock} = ppu, dots)
      when dots > 0 and clock < @vblank_start and rem(clock, @dots_per_line) >= @oam_dots do
    dot = rem(clock, @dots_per_line)
    hblank = hblank_dot(ppu)

    if (dot < hblank and dot + dots < hblank) or
         (dot >= hblank and dot + dots < @dots_per_line),
       do: {%{ppu | clock: clock + dots}, []},
       else: advance(ppu, dots, [])
  end

  def tick(%__MODULE__{clock: clock} = ppu, dots)
      when dots > 0 and clock >= @vblank_start and
             rem(clock, @dots_per_line) + dots < @dots_per_line,
      do: {%{ppu | clock: clock + dots}, []}

  def tick(%__MODULE__{} = ppu, dots) when dots > 0, do: advance(ppu, dots, [])

  defp advance(ppu, 0, signals), do: {ppu, :lists.reverse(signals)}

  defp advance(ppu, dots, signals) do
    {distance, event} = next_event(ppu)

    if dots < distance do
      {%{ppu | clock: ppu.clock + dots}, :lists.reverse(signals)}
    else
      ppu = %{ppu | clock: ppu.clock + distance}
      {ppu, emitted} = handle_event(ppu, event)
      signals = Enum.reduce(emitted, signals, fn signal, acc -> [signal | acc] end)
      advance(ppu, dots - distance, signals)
    end
  end

  defp next_event(%__MODULE__{clock: clock}) when clock >= @vblank_start do
    dot = rem(clock, @dots_per_line)
    {@dots_per_line - dot, :line_end}
  end

  defp next_event(%__MODULE__{clock: clock} = ppu) do
    dot = rem(clock, @dots_per_line)
    hblank = hblank_dot(ppu)

    cond do
      dot < @oam_dots -> {@oam_dots - dot, :transfer}
      dot < hblank -> {hblank - dot, :hblank}
      true -> {@dots_per_line - dot, :line_end}
    end
  end

  defp handle_event(ppu, :transfer) do
    %{ppu | transfer_end: hblank_dot(ppu, ly(ppu))}
    |> refresh_stat()
  end

  defp handle_event(ppu, :hblank) do
    ppu = render_line(ppu)
    refresh_stat(ppu)
  end

  defp handle_event(%__MODULE__{clock: @frame_dots} = ppu, :line_end) do
    ppu =
      %{ppu | clock: 0, transfer_end: @minimum_transfer_end, lines: [], window_line: 0}
      |> reset_renderer_capture()

    refresh_stat(ppu)
  end

  defp handle_event(%__MODULE__{clock: @vblank_start} = ppu, :line_end) do
    {frame, renderer_state, lcd_frame_state} = display_frame(ppu)
    number = ppu.frame_number

    ppu = %{
      ppu
      | frame: frame,
        lines: [],
        frame_number: number + 1,
        lcd_frame_state: lcd_frame_state,
        lcd_off_dots: 0,
        renderer_state: renderer_state
    }

    {ppu, stat} = refresh_stat(ppu)
    {ppu, [{:frame, number, frame}, :vblank | stat]}
  end

  defp handle_event(ppu, :line_end),
    do: refresh_stat(%{ppu | transfer_end: @minimum_transfer_end})

  # The LCD panel does not present the first frame generated after LCDC.7 is
  # enabled. DMG panels go blank; CGB panels briefly retain the previously
  # presented frame, then decay to white. A CGB does not suppress two
  # consecutive frames.
  defp display_frame(%__MODULE__{lcd_frame_state: :suppress} = ppu) do
    frame =
      if ppu.model == :cgb and ppu.lcd_off_dots <= @cgb_frame_repeat_dots,
        do: ppu.frame,
        else: initial_frame(ppu.model)

    {frame, ppu.renderer_state, :suppressed}
  end

  defp display_frame(ppu) do
    {frame, renderer_state} = finish_frame(ppu)
    {frame, renderer_state, :steady}
  end

  defp finish_frame(%__MODULE__{renderer: :native} = ppu),
    do: {ppu.lines |> :lists.reverse() |> IO.iodata_to_binary(), nil}

  defp finish_frame(ppu) do
    deferred = %DeferredFrame{
      model: ppu.model,
      renderer: ppu.renderer,
      lines: %{
        controls: :lists.reverse(ppu.lines),
        snapshot: ppu.renderer_snapshot,
        events: :lists.reverse(ppu.renderer_events)
      },
      state: ppu.renderer_state
    }

    {deferred, ppu.renderer_state}
  end

  defp lcd_startup_state(%__MODULE__{model: :cgb, lcd_frame_state: :suppressed}), do: :steady
  defp lcd_startup_state(_ppu), do: :suppress

  defp lcd_off_dots(ppu, old_lcdc),
    do: if((old_lcdc &&& 0x80) == 0, do: ppu.lcd_off_dots, else: 0)

  @doc false
  def resolve_frame(%DeferredFrame{} = frame) do
    apply(frame.renderer, :render, [frame.model, frame.lines, frame.state])
  end

  def resolve_frame(frame) when is_binary(frame), do: {frame, nil}

  if @dynamic_renderers do
    defp render_line(%__MODULE__{renderer: :native} = ppu), do: render_native_line(ppu)
    defp render_line(%__MODULE__{} = ppu), do: capture_renderer_controls(ppu)
  else
    if @renderer == :native do
      defp render_line(ppu), do: render_native_line(ppu)
    else
      defp render_line(ppu), do: capture_renderer_controls(ppu)
    end
  end

  if @renderer == :native or @dynamic_renderers do
    # CGB composition remains separate from DMG so color metadata and RGB output
    # add no work to the common DMG path.
    defp render_native_line(
           %__MODULE__{model: :cgb, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu
         )
         when (lcdc &&& 0x02) == 0 do
      {colors, ppu} = cgb_background_line(ppu, ly(ppu), lcdc)
      line = apply_cgb_palette(colors, elem(ppu.color_cache, 0))
      %{ppu | lines: [line | ppu.lines]}
    end

    defp render_native_line(
           %__MODULE__{model: :cgb, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu
         ) do
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
    defp render_native_line(
           %__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, _, _, _, _, _}} = ppu
         )
         when (lcdc &&& 0x03) == 0,
         do: %{ppu | lines: [@blank_line | ppu.lines]}

    # Object-disabled games take the background-only path without OAM scanning.
    defp render_native_line(
           %__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, bgp, _, _, _, _}} = ppu
         )
         when (lcdc &&& 0x02) == 0 do
      {colors, ppu} = background_line(ppu, ly(ppu), lcdc)
      line = apply_palette(colors, bgp)
      %{ppu | lines: [line | ppu.lines]}
    end

    defp render_native_line(
           %__MODULE__{model: :dmg, registers: {lcdc, _, _, _, _, bgp, obp0, obp1, _, _}} = ppu
         ) do
      line_number = ly(ppu)
      {colors, ppu} = background_line(ppu, line_number, lcdc)
      height = if (lcdc &&& 0x04) == 0, do: 8, else: 16
      sprites = select_sprites(ppu.oam, line_number, height, 0, 0, [])
      line = compose_sprites(colors, sprites, ppu.vram, line_number, height, bgp, obp0, obp1)
      %{ppu | lines: [line | ppu.lines]}
    end
  end

  if @renderer != :native or @dynamic_renderers do
    defp capture_renderer_controls(
           %__MODULE__{registers: {lcdc, _, scy, scx, _, bgp, obp0, obp1, wy, wx}} = ppu
         ) do
      line = ly(ppu)
      visible = (lcdc &&& 0x20) != 0 and line >= wy and wx - 7 < @width
      controls = <<lcdc, scy, scx, bgp, obp0, obp1, wy, wx, ppu.window_line>>
      ppu = if visible, do: %{ppu | window_line: ppu.window_line + 1}, else: ppu
      %{ppu | lines: [controls | ppu.lines]}
    end
  end

  if @renderer == :native and not @dynamic_renderers do
    defp reset_renderer_capture(ppu),
      do: %{ppu | renderer_snapshot: nil, renderer_events: []}

    defp put_renderer_bytes(_old, updated, _kind, _offset, _data), do: updated
    defp put_renderer_byte(_old, _kind, _address, _value, updated), do: updated
  else
    if @dynamic_renderers do
      defp reset_renderer_capture(%__MODULE__{renderer: :native} = ppu),
        do: %{ppu | renderer_snapshot: nil, renderer_events: []}
    end

    defp reset_renderer_capture(ppu),
      do: %{ppu | renderer_snapshot: {ppu.vram, ppu.oam, ppu.color_ram}, renderer_events: []}

    defp put_renderer_bytes(old, updated, kind, offset, data) do
      data
      |> :binary.bin_to_list()
      |> Enum.with_index(offset)
      |> Enum.reduce(updated, fn {value, address}, ppu ->
        put_renderer_byte(old, kind, address, value, ppu)
      end)
    end

    if @dynamic_renderers do
      defp put_renderer_byte(
             %__MODULE__{renderer: :native},
             _kind,
             _address,
             _value,
             updated
           ),
           do: updated
    end

    defp put_renderer_byte(old, kind, address, value, updated) do
      effective_line = ly(old) + if(dot(old) >= hblank_dot(old), do: 1, else: 0)

      cond do
        memory_byte(old, kind, address) == memory_byte(updated, kind, address) ->
          updated

        effective_line == 0 and old.lines == [] ->
          %{
            updated
            | renderer_snapshot: snapshot_put(updated.renderer_snapshot, kind, address, value)
          }

        effective_line < @height ->
          kind = if kind == :vram, do: 0, else: if(kind == :oam, do: 1, else: 2)

          %{
            updated
            | renderer_events: [{effective_line, kind, address, value} | updated.renderer_events]
          }

        true ->
          updated
      end
    end

    defp memory_byte(ppu, :vram, address), do: vram_byte(ppu.vram, address)
    defp memory_byte(ppu, :oam, address), do: :binary.at(ppu.oam, address)

    defp memory_byte(ppu, :palette, address) when address < 64,
      do: :binary.at(elem(ppu.color_ram, 0), address)

    defp memory_byte(ppu, :palette, address),
      do: :binary.at(elem(ppu.color_ram, 1), address - 64)

    defp snapshot_put({vram, oam, palettes}, :vram, address, value),
      do: {put_vram_byte(vram, address, value), oam, palettes}

    defp snapshot_put({vram, oam, palettes}, :oam, address, value),
      do: {vram, put_binary_byte(oam, address, value), palettes}

    defp snapshot_put({vram, oam, {bg, obj}}, :palette, address, value) when address < 64,
      do: {vram, oam, {put_binary_byte(bg, address, value), obj}}

    defp snapshot_put({vram, oam, {bg, obj}}, :palette, address, value),
      do: {vram, oam, {bg, put_binary_byte(obj, address - 64, value)}}
  end

  if @renderer == :native or @dynamic_renderers do
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
      apply_cgb_metadata(colors, metadata)
    end

    defp reverse_row(<<a, b, c, d, e, f, g, h>>), do: <<h, g, f, e, d, c, b, a>>

    defp apply_cgb_metadata(<<a, b, c, d, e, f, g, h>>, metadata),
      do:
        <<a ||| metadata, b ||| metadata, c ||| metadata, d ||| metadata, e ||| metadata,
          f ||| metadata, g ||| metadata, h ||| metadata>>

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
           :binary.at(oam, offset + 3)}

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
      objects = cgb_sprite_overlay(sprites, vram, line, height, @blank_line)

      colors
      |> compose_cgb_pixels(objects, lcdc, bg, obj)
      |> IO.iodata_to_binary()
    end

    defp compose_cgb_pixels(colors, objects, lcdc, bg, obj) when (lcdc &&& 0x01) == 0,
      do: compose_cgb_pixels_no_priority(colors, objects, bg, obj)

    defp compose_cgb_pixels(colors, objects, _lcdc, bg, obj),
      do: compose_cgb_pixels_with_priority(colors, objects, bg, obj)

    defp compose_cgb_pixels_no_priority(<<>>, <<>>, _bg, _obj), do: []

    defp compose_cgb_pixels_no_priority(
           <<m0, m1, m2, m3, m4, m5, m6, m7, colors::binary>>,
           <<o0, o1, o2, o3, o4, o5, o6, o7, objects::binary>>,
           bg,
           obj
         ) do
      [
        cgb_pixel_no_priority(m0, o0, bg, obj),
        cgb_pixel_no_priority(m1, o1, bg, obj),
        cgb_pixel_no_priority(m2, o2, bg, obj),
        cgb_pixel_no_priority(m3, o3, bg, obj),
        cgb_pixel_no_priority(m4, o4, bg, obj),
        cgb_pixel_no_priority(m5, o5, bg, obj),
        cgb_pixel_no_priority(m6, o6, bg, obj),
        cgb_pixel_no_priority(m7, o7, bg, obj)
        | compose_cgb_pixels_no_priority(colors, objects, bg, obj)
      ]
    end

    defp cgb_pixel_no_priority(metadata, 0, bg, _obj), do: elem(bg, metadata &&& 0x1F)
    defp cgb_pixel_no_priority(_metadata, object, _bg, obj), do: elem(obj, object &&& 0x1F)

    defp compose_cgb_pixels_with_priority(<<>>, <<>>, _bg, _obj), do: []

    defp compose_cgb_pixels_with_priority(
           <<m0, m1, m2, m3, m4, m5, m6, m7, colors::binary>>,
           <<o0, o1, o2, o3, o4, o5, o6, o7, objects::binary>>,
           bg,
           obj
         ) do
      [
        cgb_pixel_with_priority(m0, o0, bg, obj),
        cgb_pixel_with_priority(m1, o1, bg, obj),
        cgb_pixel_with_priority(m2, o2, bg, obj),
        cgb_pixel_with_priority(m3, o3, bg, obj),
        cgb_pixel_with_priority(m4, o4, bg, obj),
        cgb_pixel_with_priority(m5, o5, bg, obj),
        cgb_pixel_with_priority(m6, o6, bg, obj),
        cgb_pixel_with_priority(m7, o7, bg, obj)
        | compose_cgb_pixels_with_priority(colors, objects, bg, obj)
      ]
    end

    defp cgb_pixel_with_priority(metadata, 0, bg, _obj), do: elem(bg, metadata &&& 0x1F)

    defp cgb_pixel_with_priority(metadata, object, bg, _obj)
         when (metadata &&& 0x03) != 0 and
                ((metadata &&& 0x20) != 0 or (object &&& 0x20) != 0),
         do: elem(bg, metadata &&& 0x1F)

    defp cgb_pixel_with_priority(_metadata, object, _bg, obj), do: elem(obj, object &&& 0x1F)

    # Resolve each selected object's eight-pixel row once, in OAM priority order.
    # One metadata byte records occupancy, palette, priority, and color so the RGB
    # compositor needs a single lookup instead of scanning up to ten objects for
    # every screen pixel.
    defp cgb_sprite_overlay([], _vram, _line, _height, overlay), do: overlay

    defp cgb_sprite_overlay([{left, _top, _tile, _attrs} | sprites], vram, line, height, overlay)
         when left >= @width or left <= -8,
         do: cgb_sprite_overlay(sprites, vram, line, height, overlay)

    defp cgb_sprite_overlay([{left, top, tile, attrs} | sprites], vram, line, height, overlay) do
      source_y = line - top
      source_y = if (attrs &&& 0x40) == 0, do: source_y, else: height - 1 - source_y
      tile = if height == 8, do: tile, else: (tile &&& 0xFE) + (source_y >>> 3)
      bank_offset = if (attrs &&& 0x08) == 0, do: 0, else: 0x2000
      offset = bank_offset + tile * 16 + (source_y &&& 0x07) * 2
      low = vram_byte(vram, offset)
      high = vram_byte(vram, offset + 1)
      colors = combine_planes(elem(@bit_rows, low), elem(@bit_rows, high))
      colors = if (attrs &&& 0x20) == 0, do: colors, else: reverse_row(colors)
      visible_left = max(left, 0)
      source_x = visible_left - left
      count = min(8 - source_x, @width - visible_left)
      colors = binary_part(colors, source_x, count)
      existing = binary_part(overlay, visible_left, count)
      metadata = 0x40 ||| (attrs &&& 0x07) <<< 2 ||| (attrs &&& 0x80) >>> 2
      merged = merge_cgb_sprite_row(existing, colors, metadata, [])
      overlay = replace_binary(overlay, visible_left, merged)
      cgb_sprite_overlay(sprites, vram, line, height, overlay)
    end

    defp merge_cgb_sprite_row(<<>>, <<>>, _metadata, acc),
      do: acc |> :lists.reverse() |> :erlang.list_to_binary()

    defp merge_cgb_sprite_row(<<0, existing::binary>>, <<color, colors::binary>>, metadata, acc)
         when color != 0,
         do: merge_cgb_sprite_row(existing, colors, metadata, [metadata ||| color | acc])

    defp merge_cgb_sprite_row(
           <<existing, rest::binary>>,
           <<_color, colors::binary>>,
           metadata,
           acc
         ),
         do: merge_cgb_sprite_row(rest, colors, metadata, [existing | acc])
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
         %__MODULE__{color_ram: ram, color_indexes: indexes} = ppu,
         palette
       ) do
    if mode(ppu) == 3,
      do: 0xFF,
      else: :binary.at(elem(ram, palette), elem(indexes, palette) &&& 0x3F)
  end

  # CGB hardware still advances an auto-incrementing palette index when a
  # mode-3 data write is blocked.
  defp write_color_data(
         %__MODULE__{color_ram: ram, color_cache: cache, color_indexes: indexes} = ppu,
         palette,
         value
       ) do
    if mode(ppu) == 3 do
      increment_color_index(ppu, palette)
    else
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
  end

  defp mode3_penalty(%__MODULE__{registers: {lcdc, _, _, _, _, _, _, _, _, _}}, line)
       when line >= @height or (lcdc &&& 0x80) == 0,
       do: 0

  defp mode3_penalty(
         %__MODULE__{
           registers: {lcdc, _, _, scx, _, _, _, _, wy, wx},
           oam: oam,
           model: model
         },
         line
       ) do
    window_x = wx - 7

    window? =
      (lcdc &&& 0x20) != 0 and (model == :cgb or (lcdc &&& 0x01) != 0) and
        line >= wy and window_x < @width

    height = if (lcdc &&& 0x04) == 0, do: 8, else: 16

    sprites =
      if (lcdc &&& 0x02) == 0 do
        []
      else
        oam
        |> penalty_sprites(line, height, 0, 0, [])
        |> Enum.sort_by(fn {x, index} -> {x, index} end)
      end

    scroll_penalty = scx &&& 0x07
    window_penalty = if window?, do: 6, else: 0

    scroll_penalty + window_penalty +
      object_penalty(sprites, scx, window?, window_x, MapSet.new(), 0)
  end

  defp penalty_sprites(_oam, _line, _height, 40, _count, sprites), do: sprites
  defp penalty_sprites(_oam, _line, _height, _index, 10, sprites), do: sprites

  defp penalty_sprites(oam, line, height, index, count, sprites) do
    offset = index * 4
    y = :binary.at(oam, offset) - 16

    if line >= y and line < y + height do
      x = :binary.at(oam, offset + 1)
      penalty_sprites(oam, line, height, index + 1, count + 1, [{x, index} | sprites])
    else
      penalty_sprites(oam, line, height, index + 1, count, sprites)
    end
  end

  defp object_penalty([], _scx, _window?, _window_x, _tiles, penalty), do: penalty

  defp object_penalty([{0, _index} | sprites], scx, window?, window_x, tiles, penalty),
    do: object_penalty(sprites, scx, window?, window_x, tiles, penalty + 11)

  defp object_penalty([{x, _index} | sprites], scx, window?, window_x, tiles, penalty)
       when x < 168 do
    screen_x = x - 8

    {layer, source_x} =
      if window? and screen_x >= window_x,
        do: {:window, screen_x - window_x},
        else: {:background, screen_x + scx}

    tile = {layer, Integer.floor_div(source_x, 8)}

    {fetch_penalty, tiles} =
      if MapSet.member?(tiles, tile) do
        {0, tiles}
      else
        {max(5 - Integer.mod(source_x, 8), 0), MapSet.put(tiles, tile)}
      end

    object_penalty(sprites, scx, window?, window_x, tiles, penalty + fetch_penalty + 6)
  end

  defp object_penalty([_sprite | sprites], scx, window?, window_x, tiles, penalty),
    do: object_penalty(sprites, scx, window?, window_x, tiles, penalty)

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
