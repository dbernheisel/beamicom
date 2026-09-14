defmodule Beamicom.SNES.PPU do
  @moduledoc """
  Native S-PPU register file and frame renderer.

  The register path implements forced blank/brightness, BG mode and tile-map
  bases, BG tile-data bases, scroll, VRAM addressing/increment, CGRAM writes,
  main/sub-screen enables, windows, color math, Mode 7 transforms, and SETINI.
  The native renderer supports Mode 0, Mode 1, Mode 7, and OBJ. Mosaic,
  offset-per-tile modes, hires, and interlace field weaving are pending.

  VRAM and CGRAM use fixed persistent arrays so a byte write updates a shallow
  tree rather than copying the complete memory binary.
  """

  import Bitwise

  @compile {:no_warn_undefined, Beamicom.SNES.Nx.PPURenderer}

  @width 256
  @render_workers 4
  @mode0_layers [
    {:obj, 3},
    {:bg, 0, 2, 1},
    {:bg, 1, 2, 1},
    {:obj, 2},
    {:bg, 0, 2, 0},
    {:bg, 1, 2, 0},
    {:obj, 1},
    {:bg, 2, 2, 1},
    {:bg, 3, 2, 1},
    {:obj, 0},
    {:bg, 2, 2, 0},
    {:bg, 3, 2, 0}
  ]
  @mode1_bg3_layers [
    {:bg, 2, 2, 1},
    {:obj, 3},
    {:bg, 0, 4, 1},
    {:bg, 1, 4, 1},
    {:obj, 2},
    {:bg, 0, 4, 0},
    {:bg, 1, 4, 0},
    {:obj, 1},
    {:obj, 0},
    {:bg, 2, 2, 0}
  ]
  @mode1_layers [
    {:obj, 3},
    {:bg, 0, 4, 1},
    {:bg, 1, 4, 1},
    {:obj, 2},
    {:bg, 0, 4, 0},
    {:bg, 1, 4, 0},
    {:obj, 1},
    {:bg, 2, 2, 1},
    {:obj, 0},
    {:bg, 2, 2, 0}
  ]
  @mode7_layers [
    {:obj, 3},
    {:obj, 2},
    {:obj, 1},
    {:bg, 0, 7, 0},
    {:obj, 0}
  ]

  defstruct vram: :array.new(0x10000, default: 0, fixed: true),
            cache_identity: nil,
            cgram: :array.new(256, default: 0, fixed: true),
            oam: :array.new(544, default: 0, fixed: true),
            brightness: 0,
            force_blank?: true,
            bg_mode: 0,
            bg3_priority?: false,
            bg_tile_size: 0,
            bg_sc: {0, 0, 0, 0},
            bg_name_base: {0, 0, 0, 0},
            bg_hofs: {0, 0, 0, 0},
            bg_vofs: {0, 0, 0, 0},
            scroll_latch: 0,
            m7_latch: 0,
            m7sel: 0,
            m7hofs: 0,
            m7vofs: 0,
            m7a: 0,
            m7b: 0,
            m7c: 0,
            m7d: 0,
            m7x: 0,
            m7y: 0,
            m7_product: 0,
            obsel: 0,
            oamadd: 0,
            oam_version: 0,
            vmain: 0,
            vmadd: 0,
            vram_read_buffer: 0,
            cgadd: 0,
            cgram_latch: nil,
            window_select: {0, 0, 0},
            window_positions: {0, 0, 0, 0},
            window_logic: {0, 0},
            main_screen: 0,
            sub_screen: 0,
            main_window: 0,
            sub_window: 0,
            color_window_select: 0,
            color_math: 0,
            fixed_color: 0,
            interlace?: false,
            overscan?: false,
            frame_number: 0,
            frame_ready: nil,
            scanline_states: nil,
            render_dirty?: true,
            vram_version: 0,
            vram_page_versions: List.duplicate(0, 256) |> List.to_tuple(),
            vram_block_versions: List.duplicate(0, 8) |> List.to_tuple(),
            cgram_version: 0,
            cached_render_key: nil,
            cached_frame_data: nil,
            cached_frame_height: nil,
            rendered_frames: 0,
            reused_frames: 0

  @type frame :: %{
          number: non_neg_integer(),
          width: 256,
          height: 224 | 239,
          pixel_format: :rgb24,
          data: binary()
        }
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{cache_identity: make_ref()}

  @spec write(t(), 0x2100..0x213F, byte()) :: t()
  def write(ppu, 0x2100, value) do
    force_blank? = (value &&& 0x80) != 0
    brightness = value &&& 0x0F

    ppu
    |> mark_dirty_if(ppu.force_blank? != force_blank? or ppu.brightness != brightness)
    |> Map.merge(%{force_blank?: force_blank?, brightness: brightness})
  end

  def write(ppu, 0x2101, value), do: update_visual(ppu, %{obsel: value})

  def write(ppu, 0x2105, value),
    do:
      update_visual(ppu, %{
        bg_mode: value &&& 0x07,
        bg3_priority?: (value &&& 0x08) != 0,
        bg_tile_size: value >>> 4
      })

  def write(ppu, 0x2102, value), do: %{ppu | oamadd: (ppu.oamadd &&& 0x100) ||| value}

  def write(ppu, 0x2103, value),
    do: %{ppu | oamadd: (ppu.oamadd &&& 0x0FF) ||| (value &&& 1) <<< 8}

  def write(ppu, 0x2104, value) do
    address = rem(ppu.oamadd, 544)
    dirty? = :array.get(address, ppu.oam) != value

    %{
      ppu
      | oam: :array.set(address, value, ppu.oam),
        oamadd: rem(address + 1, 544),
        oam_version: ppu.oam_version + if(dirty?, do: 1, else: 0),
        render_dirty?: ppu.render_dirty? or dirty?
    }
  end

  def write(ppu, register, value) when register in 0x2107..0x210A do
    bg = register - 0x2107
    update_visual(ppu, %{bg_sc: put_elem(ppu.bg_sc, bg, value)})
  end

  def write(ppu, 0x210B, value),
    do:
      update_visual(ppu, %{
        bg_name_base: ppu.bg_name_base |> put_elem(0, value &&& 0x0F) |> put_elem(1, value >>> 4)
      })

  def write(ppu, 0x210C, value),
    do:
      update_visual(ppu, %{
        bg_name_base: ppu.bg_name_base |> put_elem(2, value &&& 0x0F) |> put_elem(3, value >>> 4)
      })

  def write(ppu, register, value) when register in 0x210D..0x2114 do
    bg = div(register - 0x210D, 2)
    vertical? = rem(register - 0x210D, 2) == 1

    ppu =
      if vertical? do
        scroll = (value <<< 8 ||| ppu.scroll_latch) &&& 0x03FF
        bg_vofs = put_elem(ppu.bg_vofs, bg, scroll)

        %{
          ppu
          | bg_vofs: bg_vofs,
            scroll_latch: value,
            render_dirty?: ppu.render_dirty? or bg_vofs != ppu.bg_vofs
        }
      else
        # Horizontal scroll preserves the old high byte's low three bits as
        # fine scroll.  The SNES shares the other byte latch between all eight
        # BG scroll registers, so HOFS cannot use the simpler VOFS formula.
        old_scroll = elem(ppu.bg_hofs, bg)

        scroll =
          (value <<< 8 ||| (ppu.scroll_latch &&& 0xF8) ||| (old_scroll >>> 8 &&& 0x07)) &&&
            0x03FF

        bg_hofs = put_elem(ppu.bg_hofs, bg, scroll)

        %{
          ppu
          | bg_hofs: bg_hofs,
            scroll_latch: value,
            render_dirty?: ppu.render_dirty? or bg_hofs != ppu.bg_hofs
        }
      end

    case register do
      0x210D -> write_m7_word(ppu, :m7hofs, value)
      0x210E -> write_m7_word(ppu, :m7vofs, value)
      _other -> ppu
    end
  end

  def write(ppu, 0x2115, value), do: %{ppu | vmain: value}
  def write(ppu, 0x2116, value), do: %{ppu | vmadd: (ppu.vmadd &&& 0xFF00) ||| value}
  def write(ppu, 0x2117, value), do: %{ppu | vmadd: (ppu.vmadd &&& 0x00FF) ||| value <<< 8}
  def write(ppu, 0x2118, value), do: write_vram(ppu, :low, value)
  def write(ppu, 0x2119, value), do: write_vram(ppu, :high, value)

  def write(ppu, 0x211A, value), do: update_visual(ppu, %{m7sel: value})

  def write(ppu, 0x211B, value) do
    ppu = write_m7_word(ppu, :m7a, value)
    %{ppu | m7_product: m7_product(ppu.m7a, ppu.m7b)}
  end

  def write(ppu, 0x211C, value) do
    ppu = write_m7_word(ppu, :m7b, value)
    %{ppu | m7_product: m7_product(ppu.m7a, ppu.m7b)}
  end

  def write(ppu, register, value) when register in 0x211D..0x2120,
    do:
      write_m7_word(
        ppu,
        %{0x211D => :m7c, 0x211E => :m7d, 0x211F => :m7x, 0x2120 => :m7y}[register],
        value
      )

  def write(ppu, 0x2121, value), do: %{ppu | cgadd: value, cgram_latch: nil}

  def write(%{cgram_latch: nil} = ppu, 0x2122, value),
    do: %{ppu | cgram_latch: value}

  def write(ppu, 0x2122, value) do
    color = ppu.cgram_latch ||| (value &&& 0x7F) <<< 8
    dirty? = :array.get(ppu.cgadd, ppu.cgram) != color

    %{
      ppu
      | cgram: :array.set(ppu.cgadd, color, ppu.cgram),
        cgadd: ppu.cgadd + 1 &&& 0xFF,
        cgram_latch: nil,
        render_dirty?: ppu.render_dirty? or dirty?,
        cgram_version: ppu.cgram_version + if(dirty?, do: 1, else: 0)
    }
  end

  def write(ppu, register, value) when register in 0x2123..0x2125 do
    update_visual(ppu, %{window_select: put_elem(ppu.window_select, register - 0x2123, value)})
  end

  def write(ppu, register, value) when register in 0x2126..0x2129 do
    update_visual(ppu, %{
      window_positions: put_elem(ppu.window_positions, register - 0x2126, value)
    })
  end

  def write(ppu, 0x212A, value),
    do: update_visual(ppu, %{window_logic: put_elem(ppu.window_logic, 0, value)})

  def write(ppu, 0x212B, value),
    do: update_visual(ppu, %{window_logic: put_elem(ppu.window_logic, 1, value)})

  def write(ppu, 0x212C, value), do: update_visual(ppu, %{main_screen: value &&& 0x1F})
  def write(ppu, 0x212D, value), do: update_visual(ppu, %{sub_screen: value &&& 0x1F})
  def write(ppu, 0x212E, value), do: update_visual(ppu, %{main_window: value &&& 0x1F})
  def write(ppu, 0x212F, value), do: update_visual(ppu, %{sub_window: value &&& 0x1F})
  def write(ppu, 0x2130, value), do: update_visual(ppu, %{color_window_select: value})
  def write(ppu, 0x2131, value), do: update_visual(ppu, %{color_math: value})

  def write(ppu, 0x2132, value) do
    component = value &&& 0x1F

    fixed_color =
      ppu.fixed_color
      |> set_color_component(0x001F, 0, component, (value &&& 0x20) != 0)
      |> set_color_component(0x03E0, 5, component, (value &&& 0x40) != 0)
      |> set_color_component(0x7C00, 10, component, (value &&& 0x80) != 0)

    update_visual(ppu, %{fixed_color: fixed_color})
  end

  def write(ppu, 0x2133, value),
    do:
      update_visual(ppu, %{
        interlace?: (value &&& 0x01) != 0,
        overscan?: (value &&& 0x04) != 0
      })

  def write(ppu, _register, _value), do: ppu

  @spec read(t(), 0x2100..0x213F, byte()) :: {byte(), t()}
  def read(ppu, 0x2139, _open_bus), do: read_vram(ppu, :low)
  def read(ppu, 0x213A, _open_bus), do: read_vram(ppu, :high)
  def read(ppu, 0x213B, _open_bus), do: read_cgram(ppu)

  def read(ppu, register, _open_bus) when register in 0x2134..0x2136,
    do: {ppu.m7_product >>> ((register - 0x2134) * 8) &&& 0xFF, ppu}

  def read(ppu, 0x213E, open_bus), do: {(open_bus &&& 0x10) ||| 0x01, ppu}
  def read(ppu, 0x213F, open_bus), do: {(open_bus &&& 0x20) ||| 0x03, ppu}
  def read(ppu, _register, open_bus), do: {open_bus, ppu}

  @doc "Completes a frame at the first vblank scanline."
  @spec enter_scanline(t(), non_neg_integer()) :: t()
  def enter_scanline(%__MODULE__{} = ppu, line) do
    if line == vblank_start(ppu) do
      {frame, ppu} = render_or_reuse_frame(ppu)
      %{ppu | frame_ready: frame, frame_number: ppu.frame_number + 1}
    else
      ppu
    end
  end

  @doc false
  def begin_frame(ppu, capture_scanlines?),
    do: %{ppu | scanline_states: if(capture_scanlines?, do: [], else: nil)}

  @doc false
  def enable_scanline_capture(%{scanline_states: nil} = ppu, completed_lines)
      when is_integer(completed_lines) and completed_lines >= 0 do
    %{ppu | scanline_states: List.duplicate(visual_state(ppu), completed_lines)}
  end

  def enable_scanline_capture(ppu, _completed_lines), do: ppu

  @doc false
  def capture_scanline(%{scanline_states: states} = ppu, line)
      when is_list(states) and line >= 1 do
    if line < vblank_start(ppu),
      do: %{ppu | scanline_states: [visual_state(ppu) | states]},
      else: ppu
  end

  def capture_scanline(ppu, _line), do: ppu

  @spec take_frame(t()) :: {frame() | nil, t()}
  def take_frame(%__MODULE__{frame_ready: frame} = ppu),
    do: {frame, %{ppu | frame_ready: nil}}

  @spec render_frame(t()) :: frame()
  def render_frame(%__MODULE__{} = ppu) do
    height = if ppu.overscan?, do: 239, else: 224

    data =
      cond do
        ppu.force_blank? or ppu.brightness == 0 or ppu.bg_mode not in [0, 1, 7] ->
          :binary.copy(<<0, 0, 0>>, @width * height)

        nx_renderer?(ppu) ->
          Beamicom.SNES.Nx.PPURenderer.render(ppu, nx_object_layer(ppu, height))

        true ->
          palette = palette(ppu)
          color_data = color_data(palette, ppu.brightness)

          render_ppu = %{
            ppu
            | vram: ppu.vram |> :array.to_list() |> :erlang.list_to_binary(),
              oam: ppu.oam |> :array.to_list() |> :erlang.list_to_binary()
          }

          scanlines = scanline_states(ppu, height)

          workers =
            :beamicom_snes
            |> Application.get_env(:render_workers, @render_workers)
            |> min(System.schedulers_online())
            |> max(1)

          height
          |> row_ranges(workers)
          |> Task.async_stream(
            fn rows -> render_rows(rows, render_ppu, scanlines, palette, color_data) end,
            ordered: true,
            max_concurrency: workers,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, rows} -> rows end)
          |> IO.iodata_to_binary()
      end

    %{
      number: ppu.frame_number,
      width: @width,
      height: height,
      pixel_format: :rgb24,
      data: data
    }
  end

  defp nx_renderer?(ppu) do
    Application.get_env(:beamicom_snes, :ppu_renderer, :native) == :nx and
      Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) and
      Beamicom.SNES.Nx.PPURenderer.supported?(ppu)
  end

  defp nx_object_layer(ppu, height) do
    scanlines = scanline_states(ppu, height)

    obsel_key =
      if scanlines,
        do: 0..(height - 1) |> Enum.map(&elem(elem(scanlines, &1), 9)) |> List.to_tuple(),
        else: ppu.obsel

    cache_key =
      {ppu.cache_identity, ppu.oam_version, object_vram_versions(ppu, obsel_key), obsel_key}

    process_key = {__MODULE__, :nx_object_layer}

    case Process.get(process_key) do
      {^cache_key, layer} ->
        layer

      _other ->
        layer = build_nx_object_layer(ppu, height, scanlines)
        Process.put(process_key, {cache_key, layer})
        layer
    end
  end

  defp build_nx_object_layer(ppu, height, scanlines) do
    obsel_key =
      if scanlines,
        do: 0..(height - 1) |> Enum.map(&elem(elem(scanlines, &1), 9)) |> List.to_tuple(),
        else: ppu.obsel

    cache_key = {ppu.cache_identity, ppu.oam_version, obsel_key}
    process_key = {__MODULE__, :nx_object_rows}

    {rows, entries} =
      case Process.get(process_key) do
        {^cache_key, entries} ->
          refresh_nx_object_rows(ppu, entries)

        _other ->
          build_nx_object_rows(ppu, height, scanlines)
      end

    Process.put(process_key, {cache_key, entries})
    IO.iodata_to_binary(rows)
  end

  defp build_nx_object_rows(ppu, height, scanlines) do
    object_ppu = %{ppu | oam: ppu.oam |> :array.to_list() |> :erlang.list_to_binary()}

    {entries, _cache} =
      Enum.map_reduce(0..(height - 1), %{}, fn y, cache ->
        row_ppu =
          if scanlines, do: apply_visual_state(object_ppu, elem(scanlines, y)), else: object_ppu

        {sprites, cache} = cached_obj_sprites(row_ppu, cache)
        selected = select_obj_sprites(sprites, y)
        pages = obj_row_vram_pages(row_ppu, selected)
        versions = obj_page_versions(row_ppu, pages)
        row = render_nx_obj_row(row_ppu, selected)
        {{row_ppu.obsel, selected, pages, versions, row}, cache}
      end)

    entries = List.to_tuple(entries)
    {entries |> Tuple.to_list() |> Enum.map(&elem(&1, 4)), entries}
  end

  defp refresh_nx_object_rows(ppu, entries) do
    {rows, entries} =
      entries
      |> Tuple.to_list()
      |> Enum.map_reduce([], fn {obsel, sprites, pages, old_versions, old_row}, entries ->
        row_ppu = %{ppu | obsel: obsel}
        versions = obj_page_versions(row_ppu, pages)

        row =
          if versions == old_versions,
            do: old_row,
            else: render_nx_obj_row(row_ppu, sprites)

        {row, [{obsel, sprites, pages, versions, row} | entries]}
      end)

    {rows, entries |> Enum.reverse() |> List.to_tuple()}
  end

  defp render_nx_obj_row(ppu, sprites) do
    {pixels, _priorities} = render_selected_obj_row(ppu, sprites)

    for x <- 0..(@width - 1), into: <<>> do
      case Map.get(pixels, x) do
        {priority, color} -> <<color, priority + 1>>
        nil -> <<0, 0>>
      end
    end
  end

  defp obj_row_vram_pages(ppu, sprites) do
    sprites
    |> Enum.flat_map(fn {x, row, size, tile, attributes} ->
      if x >= @width or x + size <= 0 do
        []
      else
        source_y = if((attributes &&& 0x80) != 0, do: size - 1 - row, else: row)

        name_offset =
          if (attributes &&& 1) != 0, do: ((ppu.obsel >>> 3 &&& 3) + 1) * 0x2000, else: 0

        base = (ppu.obsel &&& 0x07) * 0x4000 + name_offset

        for tile_x <- 0..(div(size, 8) - 1) do
          obj_tile = tile + tile_x + div(source_y, 8) * 16 &&& 0xFF
          (base + obj_tile * 32 &&& 0xFFFF) >>> 8
        end
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp obj_page_versions(ppu, pages),
    do: Enum.map(pages, &elem(ppu.vram_page_versions, &1))

  defp object_vram_versions(ppu, obsel) when is_integer(obsel) do
    base = (obsel &&& 0x03) <<< 1
    second = base + (obsel >>> 3 &&& 0x03) + 1 &&& 0x07
    {elem(ppu.vram_block_versions, base), elem(ppu.vram_block_versions, second)}
  end

  defp object_vram_versions(ppu, obsel_per_line) when is_tuple(obsel_per_line) do
    obsel_per_line
    |> Tuple.to_list()
    |> Enum.uniq()
    |> Enum.map(&{&1, object_vram_versions(ppu, &1)})
  end

  defp render_rows(rows, render_ppu, scanlines, palette, color_data) do
    rows
    |> Enum.map_reduce({%{}, %{}, %{}}, fn y, {tile_cache, color_cache, obj_cache} ->
      row_ppu =
        if scanlines, do: apply_visual_state(render_ppu, elem(scanlines, y)), else: render_ppu

      main_layers = render_layers(row_ppu, row_ppu.main_screen)
      sub_layers = render_layers(row_ppu, row_ppu.sub_screen)

      {row_palette, row_color_data, color_cache} =
        if scanlines do
          cached_color_data(row_ppu, color_cache)
        else
          {palette, color_data, color_cache}
        end

      {row, tile_cache, obj_cache} =
        render_row(
          row_ppu,
          row_palette,
          row_color_data,
          main_layers,
          sub_layers,
          y,
          tile_cache,
          obj_cache
        )

      {row, {tile_cache, color_cache, obj_cache}}
    end)
    |> elem(0)
  end

  defp row_ranges(height, workers) do
    band_height = div(height + workers - 1, workers)

    0..(workers - 1)
    |> Enum.map(fn worker ->
      first = worker * band_height
      first..min(first + band_height - 1, height - 1)
    end)
    |> Enum.reject(fn first.._last//_step -> first >= height end)
  end

  defp render_row(
         ppu,
         palette,
         {rgb_palette, components},
         main_layers,
         sub_layers,
         y,
         tile_cache,
         obj_cache
       ) do
    {bg_rows, tile_cache} =
      (main_layers ++ sub_layers)
      |> Enum.filter(&match?({:bg, _, _, _}, &1))
      |> Enum.uniq_by(fn {:bg, bg, _bpp, _priority} -> bg end)
      |> Enum.reduce({{nil, nil, nil, nil}, tile_cache}, fn {:bg, bg, bpp, _priority},
                                                            {rows, tile_cache} ->
        {row, priorities, tile_cache} = render_bg_row(ppu, bg, bpp, y, tile_cache)
        {put_elem(rows, bg, {row, priorities}), tile_cache}
      end)

    {obj_row, obj_priorities, obj_cache} =
      if Enum.any?(main_layers ++ sub_layers, &match?({:obj, _}, &1)) do
        {sprites, obj_cache} = cached_obj_sprites(ppu, obj_cache)
        {obj_row, priorities} = render_obj_row(ppu, y, sprites)
        {obj_row, priorities, obj_cache}
      else
        {%{}, 0, obj_cache}
      end

    main_layers = active_layers(main_layers, bg_rows, obj_priorities)
    sub_layers = active_layers(sub_layers, bg_rows, obj_priorities)

    row =
      if ppu.main_window == 0 and ppu.sub_window == 0 do
        for x <- 0..(@width - 1), into: <<>> do
          main = layer_pixel_unmasked(bg_rows, obj_row, x, main_layers)
          sub = layer_pixel_unmasked(bg_rows, obj_row, x, sub_layers)
          render_color(ppu, palette, rgb_palette, components, main, sub, x)
        end
      else
        for x <- 0..(@width - 1), into: <<>> do
          main = layer_pixel(ppu, bg_rows, obj_row, x, main_layers, ppu.main_window)
          sub = layer_pixel(ppu, bg_rows, obj_row, x, sub_layers, ppu.sub_window)
          render_color(ppu, palette, rgb_palette, components, main, sub, x)
        end
      end

    {row, tile_cache, obj_cache}
  end

  defp render_layers(ppu),
    do: (render_layers(ppu, ppu.main_screen) ++ render_layers(ppu, ppu.sub_screen)) |> Enum.uniq()

  defp render_layers(%{bg_mode: 0}, screen), do: enabled_layers(@mode0_layers, screen)

  defp render_layers(%{bg_mode: 1, bg3_priority?: true}, screen),
    do: enabled_layers(@mode1_bg3_layers, screen)

  defp render_layers(%{bg_mode: 1}, screen), do: enabled_layers(@mode1_layers, screen)

  defp render_layers(%{bg_mode: 7}, screen), do: enabled_layers(@mode7_layers, screen)

  defp enabled_layers(layers, screen),
    do:
      Enum.filter(layers, fn
        {:bg, bg, _bpp, _priority} -> (screen &&& 1 <<< bg) != 0
        {:obj, _priority} -> (screen &&& 0x10) != 0
      end)

  defp layer_pixel(_ppu, _bg_rows, _obj_row, _x, [], _window_mask), do: {:backdrop, 0}

  defp layer_pixel(ppu, bg_rows, obj_row, x, [{:bg, bg, _bpp, priority} | rest], mask) do
    masked? = (mask &&& 1 <<< bg) != 0 and window_masked?(ppu, bg, x)

    {row, _priorities} = elem(bg_rows, bg)

    case elem(row, x) do
      {^priority, color} when color != 0 and not masked? -> {bg, color}
      _transparent -> layer_pixel(ppu, bg_rows, obj_row, x, rest, mask)
    end
  end

  defp layer_pixel(ppu, bg_rows, obj_row, x, [{:obj, priority} | rest], mask) do
    masked? = (mask &&& 0x10) != 0 and window_masked?(ppu, :obj, x)

    case Map.get(obj_row, x) do
      {^priority, color} when not masked? -> {:obj, color}
      _transparent -> layer_pixel(ppu, bg_rows, obj_row, x, rest, mask)
    end
  end

  defp layer_pixel_unmasked(_bg_rows, _obj_row, _x, []), do: {:backdrop, 0}

  defp layer_pixel_unmasked(bg_rows, obj_row, x, [{:bg, bg, _bpp, priority} | rest]) do
    {row, _priorities} = elem(bg_rows, bg)

    case elem(row, x) do
      {^priority, color} when color != 0 -> {bg, color}
      _transparent -> layer_pixel_unmasked(bg_rows, obj_row, x, rest)
    end
  end

  defp layer_pixel_unmasked(bg_rows, obj_row, x, [{:obj, priority} | rest]) do
    case Map.get(obj_row, x) do
      {^priority, color} -> {:obj, color}
      _transparent -> layer_pixel_unmasked(bg_rows, obj_row, x, rest)
    end
  end

  defp active_layers(layers, bg_rows, obj_priorities) do
    Enum.filter(layers, fn
      {:bg, bg, _bpp, priority} ->
        {_row, priorities} = elem(bg_rows, bg)
        (priorities &&& 1 <<< priority) != 0

      {:obj, priority} ->
        (obj_priorities &&& 1 <<< priority) != 0
    end)
  end

  defp render_color(
         %{color_window_select: select, window_select: window_select} = ppu,
         palette,
         rgb_palette,
         components,
         {layer, main_index},
         {sub_layer, sub_index},
         _x
       )
       when (select &&& 0xF0) == 0 and (elem(window_select, 2) &&& 0xF0) == 0 do
    main = palette_color(ppu, palette, layer, main_index)

    if color_math_enabled?(ppu.color_math, layer) do
      second =
        if (select &&& 0x02) != 0,
          do: palette_color(ppu, palette, sub_layer, sub_index),
          else: ppu.fixed_color

      color_to_rgb(blend_color(main, second, ppu.color_math), components)
    else
      if direct_color?(ppu, layer),
        do: color_to_rgb(main, components),
        else: elem(rgb_palette, main_index)
    end
  end

  defp render_color(
         ppu,
         palette,
         rgb_palette,
         components,
         {layer, main_index},
         {sub_layer, sub_index},
         x
       ) do
    clip_mode = ppu.color_window_select >>> 6 &&& 0x03
    prevent_mode = ppu.color_window_select >>> 4 &&& 0x03
    color_window? = window_masked?(ppu, :color, x)

    main =
      if window_mode_applies?(clip_mode, color_window?),
        do: 0,
        else: palette_color(ppu, palette, layer, main_index)

    color =
      if color_math_enabled?(ppu.color_math, layer) and
           not window_mode_applies?(prevent_mode, color_window?) do
        second =
          if (ppu.color_window_select &&& 0x02) != 0,
            do: palette_color(ppu, palette, sub_layer, sub_index),
            else: ppu.fixed_color

        blend_color(main, second, ppu.color_math)
      else
        main
      end

    if color == main and not color_math_enabled?(ppu.color_math, layer) and
         not direct_color?(ppu, layer),
       do: elem(rgb_palette, main_index),
       else: color_to_rgb(color, components)
  end

  defp palette_color(ppu, palette, layer, index) when ppu.bg_mode == 7 and layer == 0 do
    if direct_color?(ppu, layer),
      do: (index &&& 0x07) <<< 2 ||| (index &&& 0x38) <<< 4 ||| (index &&& 0xC0) <<< 7,
      else: elem(palette, index)
  end

  defp palette_color(_ppu, palette, _layer, index), do: elem(palette, index)

  defp direct_color?(%{bg_mode: 7, color_window_select: select}, 0), do: (select &&& 1) != 0
  defp direct_color?(_ppu, _layer), do: false

  defp window_mode_applies?(0, _inside?), do: false
  defp window_mode_applies?(1, inside?), do: not inside?
  defp window_mode_applies?(2, inside?), do: inside?
  defp window_mode_applies?(3, _inside?), do: true

  defp window_masked?(ppu, layer, x) do
    {config, logic} = window_config(ppu, layer)
    {w1_left, w1_right, w2_left, w2_right} = ppu.window_positions
    w1? = (config &&& 0x01) != 0
    w2? = (config &&& 0x04) != 0
    w1 = window_value(x, w1_left, w1_right, (config &&& 0x02) != 0)
    w2 = window_value(x, w2_left, w2_right, (config &&& 0x08) != 0)

    case {w1?, w2?} do
      {false, false} -> false
      {true, false} -> w1
      {false, true} -> w2
      {true, true} -> combine_windows(w1, w2, logic)
    end
  end

  defp window_config(ppu, bg) when bg in 0..3 do
    register = elem(ppu.window_select, div(bg, 2))
    config = register >>> (rem(bg, 2) * 4) &&& 0x0F
    logic = elem(ppu.window_logic, 0) >>> (bg * 2) &&& 0x03
    {config, logic}
  end

  defp window_config(ppu, :obj),
    do: {elem(ppu.window_select, 2) &&& 0x0F, elem(ppu.window_logic, 1) &&& 0x03}

  defp window_config(ppu, :color),
    do: {elem(ppu.window_select, 2) >>> 4, elem(ppu.window_logic, 1) >>> 2 &&& 0x03}

  defp window_value(x, left, right, inverted?),
    do: if(inverted?, do: not (x >= left and x <= right), else: x >= left and x <= right)

  defp combine_windows(a, b, 0), do: a or b
  defp combine_windows(a, b, 1), do: a and b
  defp combine_windows(a, b, 2), do: a != b
  defp combine_windows(a, b, 3), do: a == b

  defp color_math_enabled?(math, :backdrop), do: (math &&& 0x20) != 0
  defp color_math_enabled?(math, :obj), do: (math &&& 0x10) != 0
  defp color_math_enabled?(math, bg), do: (math &&& 1 <<< bg) != 0

  defp blend_color(first, second, math) do
    subtract? = (math &&& 0x80) != 0
    half? = (math &&& 0x40) != 0

    blend = fn shift ->
      a = first >>> shift &&& 0x1F
      b = second >>> shift &&& 0x1F
      value = if subtract?, do: max(a - b, 0), else: min(a + b, 31)
      if half?, do: value >>> 1, else: value
    end

    blend.(0) ||| blend.(5) <<< 5 ||| blend.(10) <<< 10
  end

  defp color_to_rgb(color, components) do
    r = elem(components, color &&& 0x1F)
    g = elem(components, color >>> 5 &&& 0x1F)
    b = elem(components, color >>> 10 &&& 0x1F)
    <<r, g, b>>
  end

  defp color_data(palette, brightness) do
    components = List.to_tuple(for value <- 0..31, do: expand5(value, brightness))

    rgb_palette =
      palette |> Tuple.to_list() |> Enum.map(&color_to_rgb(&1, components)) |> List.to_tuple()

    {rgb_palette, components}
  end

  defp cached_color_data(ppu, color_cache) do
    key = {ppu.cgram_version, ppu.brightness}

    case color_cache do
      %{^key => result} ->
        {palette, color_data} = result
        {palette, color_data, color_cache}

      _ ->
        palette = palette(ppu)
        result = {palette, color_data(palette, ppu.brightness)}
        {palette, elem(result, 1), Map.put(color_cache, key, result)}
    end
  end

  defp cached_obj_sprites(ppu, obj_cache) do
    key = ppu.obsel

    case obj_cache do
      %{^key => sprites} ->
        {sprites, obj_cache}

      _ ->
        sprites = parse_obj_sprites(ppu)
        {sprites, Map.put(obj_cache, key, sprites)}
    end
  end

  defp parse_obj_sprites(ppu) do
    {small_size, large_size} = obj_sizes(ppu.obsel >>> 5)

    for index <- 0..127 do
      offset = index * 4
      high = :binary.at(ppu.oam, 512 + div(index, 4)) >>> (rem(index, 4) * 2)
      x = :binary.at(ppu.oam, offset) ||| (high &&& 1) <<< 8

      {
        if(x >= 256, do: x - 512, else: x),
        :binary.at(ppu.oam, offset + 1),
        if((high &&& 2) != 0, do: large_size, else: small_size),
        :binary.at(ppu.oam, offset + 2),
        :binary.at(ppu.oam, offset + 3)
      }
    end
  end

  defp render_obj_row(ppu, screen_y, parsed_sprites) do
    parsed_sprites
    |> select_obj_sprites(screen_y)
    |> then(&render_selected_obj_row(ppu, &1))
  end

  defp select_obj_sprites(parsed_sprites, screen_y) do
    parsed_sprites
    |> Enum.reduce_while({[], 0}, fn {x, y, size, tile, attributes}, {sprites, count} ->
      row = screen_y - y &&& 0xFF

      if row < size do
        sprites = [{x, row, size, tile, attributes} | sprites]
        count = count + 1

        if count == 32, do: {:halt, {sprites, count}}, else: {:cont, {sprites, count}}
      else
        {:cont, {sprites, count}}
      end
    end)
    |> elem(0)
  end

  defp render_selected_obj_row(ppu, sprites) do
    pixels =
      Enum.reduce(sprites, %{}, fn {x, row, size, tile, attributes}, pixels ->
        render_obj_sprite_row(ppu, pixels, x, row, size, tile, attributes)
      end)

    priorities =
      Enum.reduce(pixels, 0, fn {_x, {priority, _color}}, mask -> mask ||| 1 <<< priority end)

    {pixels, priorities}
  end

  defp render_obj_sprite_row(_ppu, pixels, x, _row, size, _tile, _attributes)
       when x >= @width or x + size <= 0,
       do: pixels

  defp render_obj_sprite_row(ppu, pixels, x, row, size, tile, attributes) do
    hflip? = (attributes &&& 0x40) != 0
    vflip? = (attributes &&& 0x80) != 0
    source_y = if vflip?, do: size - 1 - row, else: row
    priority = attributes >>> 4 &&& 0x03
    palette_base = 128 + (attributes >>> 1 &&& 0x07) * 16
    name_offset = if (attributes &&& 1) != 0, do: ((ppu.obsel >>> 3 &&& 3) + 1) * 0x2000, else: 0
    base = (ppu.obsel &&& 0x07) * 0x4000 + name_offset

    Enum.reduce(0..(size - 1), pixels, fn output_x, pixels ->
      screen_x = x + output_x

      if screen_x in 0..255 do
        source_x = if hflip?, do: size - 1 - output_x, else: output_x
        obj_tile = tile + div(source_x, 8) + div(source_y, 8) * 16 &&& 0xFF
        color = obj_tile_color(ppu.vram, base, obj_tile, source_x &&& 7, source_y &&& 7)

        if color == 0,
          do: pixels,
          else: Map.put(pixels, screen_x, {priority, palette_base + color})
      else
        pixels
      end
    end)
  end

  defp obj_tile_color(vram, base, tile, x, y) do
    address = base + tile * 32 + y * 2
    bit = 7 - x

    (vram_byte(vram, address) >>> bit &&& 1) |||
      (vram_byte(vram, address + 1) >>> bit &&& 1) <<< 1 |||
      (vram_byte(vram, address + 16) >>> bit &&& 1) <<< 2 |||
      (vram_byte(vram, address + 17) >>> bit &&& 1) <<< 3
  end

  defp obj_sizes(0), do: {8, 16}
  defp obj_sizes(1), do: {8, 32}
  defp obj_sizes(2), do: {8, 64}
  defp obj_sizes(3), do: {16, 32}
  defp obj_sizes(4), do: {16, 64}
  defp obj_sizes(5), do: {32, 64}
  defp obj_sizes(_), do: {16, 32}

  defp render_bg_row(ppu, bg, bpp, screen_y, tile_cache) when bpp in [2, 4] do
    x = elem(ppu.bg_hofs, bg) &&& 0x03FF
    y = screen_y + elem(ppu.bg_vofs, bg) &&& 0x03FF
    large_tiles? = (ppu.bg_tile_size &&& 1 <<< bg) != 0
    tile_width = if large_tiles?, do: 16, else: 8
    tile_y = div(y, tile_width)
    first_tile = div(x, tile_width)
    skip = rem(x, tile_width)
    tile_count = div(skip + @width + tile_width - 1, tile_width)

    {pixels, tile_cache} =
      0..(tile_count - 1)
      |> Enum.map_reduce(tile_cache, fn offset, tile_cache ->
        bg_tile_pixels(ppu, bg, bpp, first_tile + offset, tile_y, y, tile_width, tile_cache)
      end)

    pixels = pixels |> List.flatten() |> Enum.drop(skip) |> Enum.take(@width)

    priorities =
      Enum.reduce(pixels, 0, fn
        {_priority, 0}, mask -> mask
        {priority, _color}, mask -> mask ||| 1 <<< priority
      end)

    {List.to_tuple(pixels), priorities, tile_cache}
  end

  defp render_bg_row(%{bg_mode: 7} = ppu, 0, 7, screen_y, tile_cache) do
    a = signed16(ppu.m7a)
    b = signed16(ppu.m7b)
    c = signed16(ppu.m7c)
    d = signed16(ppu.m7d)
    center_x = signed13(ppu.m7x)
    center_y = signed13(ppu.m7y)
    hofs = signed13(ppu.m7hofs)
    vofs = signed13(ppu.m7vofs)
    screen_y = if((ppu.m7sel &&& 0x02) != 0, do: 255 - (screen_y + 1), else: screen_y + 1)
    xx = clip_m7_offset(hofs - center_x)
    yy = clip_m7_offset(vofs - center_y)
    row_x = band64(b * screen_y) + band64(b * yy) + (center_x <<< 8)
    row_y = band64(d * screen_y) + band64(d * yy) + (center_y <<< 8)

    pixels =
      for output_x <- 0..(@width - 1) do
        screen_x = if((ppu.m7sel &&& 0x01) != 0, do: 255 - output_x, else: output_x)
        texture_x = (a * screen_x + band64(a * xx) + row_x) >>> 8
        texture_y = (c * screen_x + band64(c * xx) + row_y) >>> 8
        color = mode7_color(ppu, texture_x, texture_y)
        {0, color}
      end

    priorities = if Enum.any?(pixels, fn {_priority, color} -> color != 0 end), do: 1, else: 0
    {List.to_tuple(pixels), priorities, tile_cache}
  end

  defp mode7_color(ppu, texture_x, texture_y) do
    repeat = ppu.m7sel >>> 6

    cond do
      repeat in [0, 1] ->
        fetch_mode7_color(ppu.vram, texture_x &&& 0x3FF, texture_y &&& 0x3FF)

      texture_x in 0..0x3FF and texture_y in 0..0x3FF ->
        fetch_mode7_color(ppu.vram, texture_x, texture_y)

      repeat == 3 ->
        mode7_tile_pixel(ppu.vram, 0, texture_x, texture_y)

      true ->
        0
    end
  end

  defp fetch_mode7_color(vram, x, y) do
    tilemap_address = (y &&& bnot(7)) <<< 5 ||| (x >>> 2 &&& bnot(1))
    tile = vram_byte(vram, tilemap_address)
    mode7_tile_pixel(vram, tile, x, y)
  end

  defp mode7_tile_pixel(vram, tile, x, y),
    do: vram_byte(vram, 1 + tile * 128 + (y &&& 7) * 16 + (x &&& 7) * 2)

  defp band64(value), do: value &&& bnot(63)

  defp clip_m7_offset(value),
    do: if((value &&& 0x2000) != 0, do: value ||| bnot(0x3FF), else: value &&& 0x3FF)

  defp signed13(value) do
    value = value &&& 0x1FFF
    if (value &&& 0x1000) != 0, do: value - 0x2000, else: value
  end

  defp signed16(value) do
    value = value &&& 0xFFFF
    if (value &&& 0x8000) != 0, do: value - 0x10000, else: value
  end

  defp bg_tile_pixels(ppu, bg, bpp, tile_x, tile_y, y, tile_width, tile_cache) do
    entry = tilemap_entry(ppu, bg, tile_x, tile_y)
    tile = entry &&& 0x03FF
    hflip? = (entry &&& 0x4000) != 0
    vflip? = (entry &&& 0x8000) != 0
    py = rem(y, tile_width)
    py = if vflip?, do: tile_width - 1 - py, else: py
    tile = tile + div(py, 8) * 16
    {left, tile_cache} = cached_tile_row(ppu, bg, bpp, tile, rem(py, 8), tile_cache)

    {right, tile_cache} =
      if tile_width == 16,
        do: cached_tile_row(ppu, bg, bpp, tile + 1, rem(py, 8), tile_cache),
        else: {nil, tile_cache}

    palette = entry >>> 10 &&& 0x07
    palette_base = if ppu.bg_mode == 0, do: bg * 32, else: 0
    priority = entry >>> 13 &&& 1
    color_base = palette_base + palette * (1 <<< bpp)

    pixels =
      for output_x <- 0..(tile_width - 1) do
        source_x = if hflip?, do: tile_width - 1 - output_x, else: output_x
        row = if source_x < 8, do: left, else: right
        tile_color = elem(row, source_x &&& 7)

        # Tile color zero is transparent before the palette base is applied.
        # Treating palette N's color zero as index N*16 makes stencil layers
        # opaque (notably the Final Fantasy III title-logo mask).
        color = if tile_color == 0, do: 0, else: color_base + tile_color
        {priority, color}
      end

    {pixels, tile_cache}
  end

  defp cached_tile_row(ppu, bg, bpp, tile, row, tile_cache) do
    key = {elem(ppu.bg_name_base, bg), bpp, tile, row}

    case tile_cache do
      %{^key => pixels} ->
        {pixels, tile_cache}

      _ ->
        pixels = decode_tile_row(ppu, bg, bpp, tile, row)
        {pixels, Map.put(tile_cache, key, pixels)}
    end
  end

  defp tilemap_entry(ppu, bg, tile_x, tile_y) do
    screen = elem(ppu.bg_sc, bg)
    size = screen &&& 0x03
    width = if size in [1, 3], do: 64, else: 32
    height = if size in [2, 3], do: 64, else: 32
    tile_x = rem(tile_x, width)
    tile_y = rem(tile_y, height)
    screen_x = div(tile_x, 32)
    screen_y = div(tile_y, 32)
    screen_number = screen_x + screen_y * if(width == 64, do: 2, else: 1)
    base = (screen &&& 0xFC) <<< 8
    word = base + screen_number * 0x400 + rem(tile_y, 32) * 32 + rem(tile_x, 32)
    vram_word(ppu, word)
  end

  defp decode_tile_row(ppu, bg, 2, tile, y) do
    base = elem(ppu.bg_name_base, bg) * 0x2000 + tile * 16
    low = vram_byte(ppu.vram, base + y * 2)
    high = vram_byte(ppu.vram, base + y * 2 + 1)

    List.to_tuple(
      for x <- 0..7 do
        bit = 7 - x
        (low >>> bit &&& 1) ||| (high >>> bit &&& 1) <<< 1
      end
    )
  end

  defp decode_tile_row(ppu, bg, 4, tile, y) do
    base = elem(ppu.bg_name_base, bg) * 0x2000 + tile * 32
    plane01 = base + y * 2
    plane23 = plane01 + 16
    p0 = vram_byte(ppu.vram, plane01)
    p1 = vram_byte(ppu.vram, plane01 + 1)
    p2 = vram_byte(ppu.vram, plane23)
    p3 = vram_byte(ppu.vram, plane23 + 1)

    List.to_tuple(
      for x <- 0..7 do
        bit = 7 - x

        (p0 >>> bit &&& 1) ||| (p1 >>> bit &&& 1) <<< 1 |||
          (p2 >>> bit &&& 1) <<< 2 ||| (p3 >>> bit &&& 1) <<< 3
      end
    )
  end

  defp palette(ppu) do
    List.to_tuple(for index <- 0..255, do: :array.get(index, ppu.cgram))
  end

  defp expand5(value, brightness), do: div(value * 255 * brightness, 31 * 15)

  defp m7_product(a, b) do
    signed_a = if a >= 0x8000, do: a - 0x10000, else: a
    multiplier = b >>> 8
    signed_b = if multiplier >= 0x80, do: multiplier - 0x100, else: multiplier
    signed_a * signed_b &&& 0xFFFFFF
  end

  defp write_vram(ppu, byte, value) do
    address = translated_vmadd(ppu) * 2 + if(byte == :high, do: 1, else: 0)
    address = address &&& 0xFFFF
    dirty? = :array.get(address, ppu.vram) != value
    vram = :array.set(address, value, ppu.vram)
    page = address >>> 8

    page_versions =
      if dirty?,
        do: put_elem(ppu.vram_page_versions, page, elem(ppu.vram_page_versions, page) + 1),
        else: ppu.vram_page_versions

    block = address >>> 13

    block_versions =
      if dirty?,
        do: put_elem(ppu.vram_block_versions, block, elem(ppu.vram_block_versions, block) + 1),
        else: ppu.vram_block_versions

    increment_on_high? = (ppu.vmain &&& 0x80) != 0

    if increment_on_high? == (byte == :high) do
      %{
        ppu
        | vram: vram,
          vmadd: ppu.vmadd + vram_increment(ppu.vmain) &&& 0xFFFF,
          render_dirty?: ppu.render_dirty? or dirty?,
          vram_version: ppu.vram_version + if(dirty?, do: 1, else: 0),
          vram_page_versions: page_versions,
          vram_block_versions: block_versions
      }
    else
      %{
        ppu
        | vram: vram,
          render_dirty?: ppu.render_dirty? or dirty?,
          vram_version: ppu.vram_version + if(dirty?, do: 1, else: 0),
          vram_page_versions: page_versions,
          vram_block_versions: block_versions
      }
    end
  end

  defp render_or_reuse_frame(ppu), do: render_or_reuse_frame(ppu, render_key(ppu))

  defp render_or_reuse_frame(%{cached_render_key: key, cached_frame_data: data} = ppu, key)
       when is_binary(data) do
    frame = %{
      number: ppu.frame_number,
      width: @width,
      height: ppu.cached_frame_height,
      pixel_format: :rgb24,
      data: data
    }

    {frame, %{ppu | reused_frames: ppu.reused_frames + 1}}
  end

  defp render_or_reuse_frame(ppu, key) do
    frame = render_frame(ppu)

    {frame,
     %{
       ppu
       | render_dirty?: false,
         cached_render_key: key,
         cached_frame_data: frame.data,
         cached_frame_height: frame.height,
         rendered_frames: ppu.rendered_frames + 1
     }}
  end

  defp render_key(ppu) do
    {
      ppu.force_blank?,
      ppu.brightness,
      ppu.bg_mode,
      ppu.bg3_priority?,
      ppu.bg_tile_size,
      ppu.obsel,
      ppu.bg_sc,
      ppu.bg_name_base,
      ppu.bg_hofs,
      ppu.bg_vofs,
      ppu.m7sel,
      ppu.m7hofs,
      ppu.m7vofs,
      ppu.m7a,
      ppu.m7b,
      ppu.m7c,
      ppu.m7d,
      ppu.m7x,
      ppu.m7y,
      ppu.window_select,
      ppu.window_positions,
      ppu.window_logic,
      ppu.main_screen,
      ppu.sub_screen,
      ppu.main_window,
      ppu.sub_window,
      ppu.color_window_select,
      ppu.color_math,
      ppu.fixed_color,
      ppu.overscan?,
      ppu.scanline_states,
      render_vram_key(ppu),
      if((ppu.main_screen &&& 0x10) != 0 or (ppu.sub_screen &&& 0x10) != 0,
        do: ppu.oam_version,
        else: 0
      ),
      ppu.cgram_version
    }
  end

  defp render_vram_key(%{bg_mode: 7} = ppu) do
    if (ppu.main_screen &&& 0x01) != 0 or (ppu.sub_screen &&& 0x01) != 0,
      do: Enum.map(0..255, fn page -> {page, elem(ppu.vram_page_versions, page)} end),
      else: render_obj_vram_key(ppu)
  end

  defp render_vram_key(ppu) do
    layers = render_layers(ppu)

    bg_pages =
      layers
      |> Enum.filter(&match?({:bg, _, _, _}, &1))
      |> Enum.uniq_by(fn {:bg, bg, _bpp, _priority} -> bg end)
      |> Enum.flat_map(fn {:bg, bg, bpp, _priority} ->
        screen = elem(ppu.bg_sc, bg)
        tilemap_base = (screen &&& 0xFC) <<< 9

        tilemap_bytes =
          case screen &&& 0x03 do
            0 -> 0x800
            3 -> 0x2000
            _ -> 0x1000
          end

        tile_base = elem(ppu.bg_name_base, bg) * 0x2000
        tile_bytes = if bpp == 2, do: 0x4000, else: 0x8000
        vram_pages(tilemap_base, tilemap_bytes) ++ vram_pages(tile_base, tile_bytes)
      end)

    obj_pages = object_vram_pages(ppu, layers)

    (bg_pages ++ obj_pages)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn page -> {page, elem(ppu.vram_page_versions, page)} end)
  end

  defp render_obj_vram_key(ppu) do
    ppu
    |> object_vram_pages(render_layers(ppu))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn page -> {page, elem(ppu.vram_page_versions, page)} end)
  end

  defp object_vram_pages(ppu, layers) do
    if Enum.any?(layers, &match?({:obj, _}, &1)) do
      base = (ppu.obsel &&& 0x07) * 0x4000
      second = base + ((ppu.obsel >>> 3 &&& 3) + 1) * 0x2000
      vram_pages(base, 0x2000) ++ vram_pages(second, 0x2000)
    else
      []
    end
  end

  defp vram_pages(base, bytes) do
    for offset <- 0..div(bytes - 1, 0x100),
        do: (base + offset * 0x100 &&& 0xFFFF) >>> 8
  end

  defp update_visual(ppu, changes) do
    dirty? = Enum.any?(changes, fn {key, value} -> Map.fetch!(ppu, key) != value end)
    ppu |> mark_dirty_if(dirty?) |> Map.merge(changes)
  end

  defp mark_dirty_if(ppu, true), do: %{ppu | render_dirty?: true}
  defp mark_dirty_if(ppu, false), do: ppu

  defp write_m7_word(ppu, key, value) do
    word = value <<< 8 ||| ppu.m7_latch

    ppu
    |> mark_dirty_if(Map.fetch!(ppu, key) != word)
    |> Map.put(key, word)
    |> Map.put(:m7_latch, value)
  end

  defp set_color_component(color, mask, shift, value, true),
    do: (color &&& bnot(mask)) ||| value <<< shift

  defp set_color_component(color, _mask, _shift, _value, false), do: color

  @doc false
  def visual_state(ppu) do
    {
      ppu.force_blank?,
      ppu.brightness,
      ppu.bg_mode,
      ppu.bg3_priority?,
      ppu.bg_tile_size,
      ppu.bg_sc,
      ppu.bg_name_base,
      ppu.bg_hofs,
      ppu.bg_vofs,
      ppu.obsel,
      ppu.window_select,
      ppu.window_positions,
      ppu.window_logic,
      ppu.main_screen,
      ppu.sub_screen,
      ppu.main_window,
      ppu.sub_window,
      ppu.color_window_select,
      ppu.color_math,
      ppu.fixed_color,
      ppu.cgram_version,
      ppu.cgram,
      ppu.m7sel,
      ppu.m7hofs,
      ppu.m7vofs,
      ppu.m7a,
      ppu.m7b,
      ppu.m7c,
      ppu.m7d,
      ppu.m7x,
      ppu.m7y
    }
  end

  defp apply_visual_state(
         ppu,
         {force_blank?, brightness, bg_mode, bg3_priority?, bg_tile_size, bg_sc, bg_name_base,
          bg_hofs, bg_vofs, obsel, window_select, window_positions, window_logic, main_screen,
          sub_screen, main_window, sub_window, color_window_select, color_math, fixed_color,
          cgram_version, cgram, m7sel, m7hofs, m7vofs, m7a, m7b, m7c, m7d, m7x, m7y}
       ) do
    %{
      ppu
      | force_blank?: force_blank?,
        brightness: brightness,
        bg_mode: bg_mode,
        bg3_priority?: bg3_priority?,
        bg_tile_size: bg_tile_size,
        bg_sc: bg_sc,
        bg_name_base: bg_name_base,
        bg_hofs: bg_hofs,
        bg_vofs: bg_vofs,
        obsel: obsel,
        window_select: window_select,
        window_positions: window_positions,
        window_logic: window_logic,
        main_screen: main_screen,
        sub_screen: sub_screen,
        main_window: main_window,
        sub_window: sub_window,
        color_window_select: color_window_select,
        color_math: color_math,
        fixed_color: fixed_color,
        cgram_version: cgram_version,
        cgram: cgram,
        m7sel: m7sel,
        m7hofs: m7hofs,
        m7vofs: m7vofs,
        m7a: m7a,
        m7b: m7b,
        m7c: m7c,
        m7d: m7d,
        m7x: m7x,
        m7y: m7y
    }
  end

  defp scanline_states(%{scanline_states: states}, height) when is_list(states) do
    if length(states) == height, do: states |> Enum.reverse() |> List.to_tuple(), else: nil
  end

  defp scanline_states(_ppu, _height), do: nil

  defp read_vram(ppu, byte) do
    address = translated_vmadd(ppu) * 2
    word = vram_word(ppu, div(address, 2))
    value = if byte == :low, do: word &&& 0xFF, else: word >>> 8
    increment_on_high? = (ppu.vmain &&& 0x80) != 0

    ppu =
      if increment_on_high? == (byte == :high),
        do: %{ppu | vmadd: ppu.vmadd + vram_increment(ppu.vmain) &&& 0xFFFF},
        else: ppu

    {value, ppu}
  end

  defp read_cgram(ppu) do
    color = :array.get(ppu.cgadd, ppu.cgram)

    case ppu.cgram_latch do
      nil -> {color &&& 0xFF, %{ppu | cgram_latch: 0}}
      _ -> {color >>> 8, %{ppu | cgadd: ppu.cgadd + 1 &&& 0xFF, cgram_latch: nil}}
    end
  end

  defp translated_vmadd(%{vmain: vmain, vmadd: address}) do
    case vmain >>> 2 &&& 0x03 do
      0 -> address
      1 -> (address &&& 0xFF00) ||| (address &&& 0x001F) <<< 3 ||| (address >>> 5 &&& 0x07)
      2 -> (address &&& 0xFE00) ||| (address &&& 0x003F) <<< 3 ||| (address >>> 6 &&& 0x07)
      3 -> (address &&& 0xFC00) ||| (address &&& 0x007F) <<< 3 ||| (address >>> 7 &&& 0x07)
    end
  end

  defp vram_increment(vmain) do
    case vmain &&& 0x03 do
      0 -> 1
      1 -> 32
      _ -> 128
    end
  end

  defp vram_word(ppu, word_address) do
    address = word_address * 2 &&& 0xFFFF
    vram_byte(ppu.vram, address) ||| vram_byte(ppu.vram, address + 1) <<< 8
  end

  defp vram_byte(vram, address) when is_binary(vram),
    do: :binary.at(vram, address &&& 0xFFFF)

  defp vram_byte(vram, address), do: :array.get(address &&& 0xFFFF, vram)

  defp vblank_start(%{overscan?: true}), do: 240
  defp vblank_start(_ppu), do: 225
end
