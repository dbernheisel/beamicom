defmodule Beamicom.GBA.PPU do
  @moduledoc """
  Scalar GBA display timing and frame-boundary state.

  The display state is captured for deterministic Mode 0, Mode 1, and Mode 3
  composition, including scanline background-control changes.
  """

  import Bitwise

  alias Beamicom.GBA.ScalarPPURenderer

  @renderer Application.compile_env(:beamicom_gba, :ppu_renderer, ScalarPPURenderer)
  @dynamic_renderers Application.compile_env(:beamicom_gba, :allow_runtime_renderers, false)

  @width 240
  @height 160
  @black_frame :binary.copy(<<0>>, @width * @height * 3)
  @bg_affine_defaults {{0x0100, 0, 0, 0x0100, 0, 0}, {0x0100, 0, 0, 0x0100, 0, 0}}
  @bg_affine_internal_defaults {{0, 0}, {0, 0}}
  @bg_affine_dirty_defaults {{false, false}, {false, false}}
  @display_effect_defaults List.duplicate(0, 11) |> List.to_tuple()
  @scanline_dispcnt_defaults List.duplicate(0, @height) |> List.to_tuple()
  @scanline_bgcnt_defaults List.duplicate({0, 0, 0, 0}, @height) |> List.to_tuple()
  @scanline_bghofs_defaults List.duplicate({0, 0, 0, 0}, @height) |> List.to_tuple()
  @scanline_bgvofs_defaults List.duplicate({0, 0, 0, 0}, @height) |> List.to_tuple()
  @scanline_bg_affine_defaults List.duplicate(@bg_affine_defaults, @height) |> List.to_tuple()

  @scanline_display_effect_defaults List.duplicate(@display_effect_defaults, @height)
                                    |> List.to_tuple()

  @enforce_keys [:renderer, :frame]
  defstruct renderer: @renderer,
            dispcnt: 0,
            bgcnt: {0, 0, 0, 0},
            bghofs: {0, 0, 0, 0},
            bgvofs: {0, 0, 0, 0},
            bg_affine: @bg_affine_defaults,
            bg_affine_internal: @bg_affine_internal_defaults,
            bg_affine_dirty: @bg_affine_dirty_defaults,
            display_effects: @display_effect_defaults,
            scanline_dispcnt: @scanline_dispcnt_defaults,
            scanline_bgcnt: @scanline_bgcnt_defaults,
            scanline_bghofs: @scanline_bghofs_defaults,
            scanline_bgvofs: @scanline_bgvofs_defaults,
            scanline_bg_affine: @scanline_bg_affine_defaults,
            scanline_display_effects: @scanline_display_effect_defaults,
            line: 0,
            phase: :hdraw,
            frame_number: 0,
            frame: @black_frame

  @doc "Creates display state using the compile-time renderer."
  def new(opts \\ []) when is_list(opts) do
    renderer = renderer(opts)
    %__MODULE__{renderer: renderer, frame: @black_frame}
  end

  @doc "Handles entry into HBlank."
  def enter_hblank(%__MODULE__{} = ppu), do: %{ppu | phase: :hblank}

  @doc "Begins the next scanline, rendering at VBlank entry and publishing at line zero."
  def begin_next_line(%__MODULE__{} = ppu, vram, palette, oam)
      when is_binary(vram) and is_binary(palette) and is_binary(oam) do
    line = rem(ppu.line + 1, 228)

    ppu = if line == @height, do: render_frame(ppu, vram, palette, oam), else: ppu
    ppu = if line == 0, do: publish_frame(ppu), else: ppu

    ppu = if line < @height, do: capture_scanline(ppu, line), else: ppu

    phase = if line in 160..227, do: :vblank, else: :hdraw
    %{ppu | line: line, phase: phase}
  end

  @doc "Writes the display-control register."
  def put_dispcnt(%__MODULE__{} = ppu, value) when value in 0x0000..0xFFFF do
    ppu |> Map.put(:dispcnt, value) |> capture_current_scanline(:dispcnt)
  end

  @doc "Resets display registers while preserving scan timing and the current frame."
  def reset_registers(%__MODULE__{} = ppu) do
    %{
      ppu
      | dispcnt: 0x80,
        bgcnt: {0, 0, 0, 0},
        bghofs: {0, 0, 0, 0},
        bgvofs: {0, 0, 0, 0},
        bg_affine: @bg_affine_defaults,
        bg_affine_internal: @bg_affine_internal_defaults,
        bg_affine_dirty: @bg_affine_dirty_defaults,
        display_effects: @display_effect_defaults,
        scanline_dispcnt: @scanline_dispcnt_defaults,
        scanline_bgcnt: @scanline_bgcnt_defaults,
        scanline_bghofs: @scanline_bghofs_defaults,
        scanline_bgvofs: @scanline_bgvofs_defaults,
        scanline_bg_affine: @scanline_bg_affine_defaults,
        scanline_display_effects: @scanline_display_effect_defaults
    }
  end

  @doc "Reads a byte from the regular-background control and scroll registers."
  def background_register(%__MODULE__{} = ppu, offset) when offset in 0x08..0x1F do
    {registers, index, byte} = background_register_location(ppu, offset)
    elem(registers, index) >>> (byte * 8) &&& 0xFF
  end

  @doc "Writes a byte to the regular-background control and scroll registers."
  def put_background_register(%__MODULE__{} = ppu, offset, value)
      when offset in 0x08..0x1F and value in 0x00..0xFF do
    {field, registers, index, byte} = background_register_location_with_field(ppu, offset)
    current = elem(registers, index)
    shift = byte * 8
    updated = (current &&& bnot(0xFF <<< shift)) ||| value <<< shift
    updated = if field in [:bghofs, :bgvofs], do: updated &&& 0x1FF, else: updated

    ppu
    |> Map.put(field, put_elem(registers, index, updated))
    |> capture_current_scanline(field)
  end

  @doc "Reads a byte from the BG2/BG3 affine parameter registers."
  def affine_register(%__MODULE__{} = ppu, offset) when offset in 0x20..0x3F do
    {background, parameter, byte, _mask} = affine_register_location(offset)
    value = ppu.bg_affine |> elem(background) |> elem(parameter)
    value >>> (byte * 8) &&& 0xFF
  end

  @doc "Writes a byte to the BG2/BG3 affine parameter registers."
  def put_affine_register(%__MODULE__{} = ppu, offset, value)
      when offset in 0x20..0x3F and value in 0x00..0xFF do
    {background, parameter, byte, mask} = affine_register_location(offset)
    parameters = elem(ppu.bg_affine, background)
    current = elem(parameters, parameter)
    shift = byte * 8
    updated = ((current &&& bnot(0xFF <<< shift)) ||| value <<< shift) &&& mask
    parameters = put_elem(parameters, parameter, updated)
    ppu = %{ppu | bg_affine: put_elem(ppu.bg_affine, background, parameters)}

    ppu =
      if parameter in [4, 5] do
        axis = parameter - 4
        internal = put_elem(elem(ppu.bg_affine_internal, background), axis, updated)
        dirty = put_elem(elem(ppu.bg_affine_dirty, background), axis, ppu.phase == :hblank)

        %{
          ppu
          | bg_affine_internal: put_elem(ppu.bg_affine_internal, background, internal),
            bg_affine_dirty: put_elem(ppu.bg_affine_dirty, background, dirty)
        }
      else
        ppu
      end

    capture_current_scanline(ppu, :bg_affine)
  end

  @doc "Reads a byte from the window, mosaic, or color-effects registers."
  def display_effect_register(%__MODULE__{} = ppu, offset) when offset in 0x40..0x55 do
    relative = offset - 0x40
    elem(ppu.display_effects, div(relative, 2)) >>> (rem(relative, 2) * 8) &&& 0xFF
  end

  @doc "Writes a byte to the window, mosaic, or color-effects registers."
  def put_display_effect_register(%__MODULE__{} = ppu, offset, value)
      when offset in 0x40..0x55 and value in 0x00..0xFF do
    relative = offset - 0x40
    index = div(relative, 2)
    shift = rem(relative, 2) * 8
    current = elem(ppu.display_effects, index)
    updated = (current &&& bnot(0xFF <<< shift)) ||| value <<< shift

    ppu
    |> Map.put(:display_effects, put_elem(ppu.display_effects, index, updated))
    |> capture_current_scanline(:display_effects)
  end

  defp render_frame(
         %__MODULE__{dispcnt: dispcnt, renderer: renderer} = ppu,
         vram,
         palette,
         oam
       ) do
    frame =
      if (dispcnt &&& 0x80) != 0 do
        @black_frame
      else
        case rem(dispcnt, 8) do
          0 -> renderer.render_mode0(vram, palette, oam, ppu)
          1 -> renderer.render_mode1(vram, palette, oam, ppu)
          3 -> renderer.render_mode3(vram, palette, oam, ppu)
          _unsupported_mode -> @black_frame
        end
      end

    %{ppu | frame: frame}
  end

  defp publish_frame(ppu), do: %{ppu | frame_number: ppu.frame_number + 1}

  defp capture_scanline(ppu, line) do
    {internal, affine} = effective_affine(ppu, line)

    %{
      ppu
      | bg_affine_internal: internal,
        bg_affine_dirty: @bg_affine_dirty_defaults,
        scanline_dispcnt: put_elem(ppu.scanline_dispcnt, line, ppu.dispcnt),
        scanline_bgcnt: put_elem(ppu.scanline_bgcnt, line, ppu.bgcnt),
        scanline_bghofs: put_elem(ppu.scanline_bghofs, line, ppu.bghofs),
        scanline_bgvofs: put_elem(ppu.scanline_bgvofs, line, ppu.bgvofs),
        scanline_bg_affine: put_elem(ppu.scanline_bg_affine, line, affine),
        scanline_display_effects:
          put_elem(ppu.scanline_display_effects, line, ppu.display_effects)
    }
  end

  defp capture_current_scanline(%{line: line, phase: :hdraw} = ppu, field)
       when line < @height do
    case field do
      :dispcnt ->
        %{ppu | scanline_dispcnt: put_elem(ppu.scanline_dispcnt, line, ppu.dispcnt)}

      :bgcnt ->
        %{ppu | scanline_bgcnt: put_elem(ppu.scanline_bgcnt, line, ppu.bgcnt)}

      :bghofs ->
        %{ppu | scanline_bghofs: put_elem(ppu.scanline_bghofs, line, ppu.bghofs)}

      :bgvofs ->
        %{ppu | scanline_bgvofs: put_elem(ppu.scanline_bgvofs, line, ppu.bgvofs)}

      :bg_affine ->
        %{ppu | scanline_bg_affine: put_elem(ppu.scanline_bg_affine, line, current_affine(ppu))}

      :display_effects ->
        %{
          ppu
          | scanline_display_effects:
              put_elem(ppu.scanline_display_effects, line, ppu.display_effects)
        }
    end
  end

  defp capture_current_scanline(ppu, _field), do: ppu

  defp current_affine(ppu) do
    0..1
    |> Enum.reduce(ppu.bg_affine, fn background, affine ->
      {x, y} = elem(ppu.bg_affine_internal, background)
      parameters = elem(affine, background) |> put_elem(4, x) |> put_elem(5, y)
      put_elem(affine, background, parameters)
    end)
  end

  defp effective_affine(ppu, line) do
    0..1
    |> Enum.reduce({ppu.bg_affine_internal, ppu.bg_affine}, fn background, {internal, affine} ->
      parameters = elem(ppu.bg_affine, background)
      current = elem(internal, background)
      dirty = elem(ppu.bg_affine_dirty, background)
      {next_x, next_y} = effective_reference(parameters, current, dirty, line)
      effective = parameters |> put_elem(4, next_x) |> put_elem(5, next_y)

      {
        put_elem(internal, background, {next_x, next_y}),
        put_elem(affine, background, effective)
      }
    end)
  end

  defp effective_reference(
         {_pa, _pb, _pc, _pd, reference_x, reference_y},
         _current,
         _dirty,
         0
       ),
       do: {reference_x, reference_y}

  defp effective_reference({_pa, pb, _pc, pd, _reference_x, _reference_y}, {x, y}, dirty, _line) do
    next_x = if elem(dirty, 0), do: x, else: add_signed16(x, pb)
    next_y = if elem(dirty, 1), do: y, else: add_signed16(y, pd)
    {next_x, next_y}
  end

  defp add_signed16(value, increment), do: value + signed16(increment) &&& 0x0FFF_FFFF

  defp background_register_location(ppu, offset) do
    {_field, registers, index, byte} = background_register_location_with_field(ppu, offset)
    {registers, index, byte}
  end

  defp background_register_location_with_field(ppu, offset) when offset in 0x08..0x0F do
    relative = offset - 0x08
    {:bgcnt, ppu.bgcnt, div(relative, 2), rem(relative, 2)}
  end

  defp background_register_location_with_field(ppu, offset) do
    relative = offset - 0x10
    layer = div(relative, 4)

    if rem(relative, 4) < 2,
      do: {:bghofs, ppu.bghofs, layer, rem(relative, 2)},
      else: {:bgvofs, ppu.bgvofs, layer, rem(relative - 2, 2)}
  end

  defp affine_register_location(offset) do
    relative = offset - 0x20
    background = div(relative, 0x10)
    register = rem(relative, 0x10)

    case register do
      byte when byte < 8 -> {background, div(byte, 2), rem(byte, 2), 0xFFFF}
      byte when byte < 12 -> {background, 4, byte - 8, 0x0FFF_FFFF}
      byte -> {background, 5, byte - 12, 0x0FFF_FFFF}
    end
  end

  defp signed16(value) when value >= 0x8000, do: value - 0x1_0000
  defp signed16(value), do: value

  if @dynamic_renderers do
    defp renderer(opts), do: Keyword.get(opts, :renderer, @renderer)
  else
    defp renderer(_opts), do: @renderer
  end
end
