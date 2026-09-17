defmodule Beamicom.SNES.PPU do
  @moduledoc """
  Native S-PPU register file and frame renderer.

  The register path implements forced blank/brightness, BG mode and tile-map
  bases, BG tile-data bases, scroll, VRAM addressing/increment, CGRAM writes,
  main/sub-screen enables, windows, color math, Mode 7 transforms, and SETINI.
  The native renderer supports all background bit depths and priority orders,
  Mode 7 transforms, mosaic, OBJ, BG3 offset-per-tile scrolling, and 512-pixel
  Mode 5/6 background fetches. Hires and pseudo-hires are downsampled into the
  public 256-pixel frame by averaging each sub/main pixel pair, while interlaced
  frames expose one field at the existing 224/239-line height.

  VRAM and CGRAM use fixed persistent arrays so a byte write updates a shallow
  tree rather than copying the complete memory binary.
  """

  import Bitwise

  @compile {:no_warn_undefined, Beamicom.SNES.Nx.PPURenderer}
  @compile {:no_warn_undefined, Beamicom.SNES.Nx.BlarggNTSC}
  @compile {:inline, vram_byte: 2, blend_component: 4}

  @width 256
  @empty_object_descriptor :binary.copy(<<0>>, 9 * 4)
  @active_display_start 88
  @render_workers 4
  @ppu1_mdr_read_registers [
    0x2104,
    0x2105,
    0x2106,
    0x2108,
    0x2109,
    0x210A,
    0x2114,
    0x2115,
    0x2116,
    0x2118,
    0x2119,
    0x211A,
    0x2124,
    0x2125,
    0x2126,
    0x2128,
    0x2129,
    0x212A
  ]
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
  @mode2_layers [
    {:obj, 3},
    {:bg, 0, 4, 1},
    {:obj, 2},
    {:bg, 1, 4, 1},
    {:obj, 1},
    {:bg, 0, 4, 0},
    {:obj, 0},
    {:bg, 1, 4, 0}
  ]
  @mode3_layers [
    {:obj, 3},
    {:bg, 0, 8, 1},
    {:obj, 2},
    {:bg, 1, 4, 1},
    {:obj, 1},
    {:bg, 0, 8, 0},
    {:obj, 0},
    {:bg, 1, 4, 0}
  ]
  @mode4_layers [
    {:obj, 3},
    {:bg, 0, 8, 1},
    {:obj, 2},
    {:bg, 1, 2, 1},
    {:obj, 1},
    {:bg, 0, 8, 0},
    {:obj, 0},
    {:bg, 1, 2, 0}
  ]
  @mode5_layers [
    {:obj, 3},
    {:bg, 0, 4, 1},
    {:obj, 2},
    {:bg, 1, 2, 1},
    {:obj, 1},
    {:bg, 0, 4, 0},
    {:obj, 0},
    {:bg, 1, 2, 0}
  ]
  @mode6_layers [
    {:obj, 3},
    {:bg, 0, 4, 1},
    {:obj, 2},
    {:obj, 1},
    {:bg, 0, 4, 0},
    {:obj, 0}
  ]
  @mode7_layers [
    {:obj, 3},
    {:obj, 2},
    {:obj, 1},
    {:bg, 0, 7, 0},
    {:obj, 0}
  ]
  @mode7_extbg_layers [
    {:obj, 3},
    {:obj, 2},
    {:bg, 1, 7, 1},
    {:obj, 1},
    {:bg, 0, 7, 0},
    {:obj, 0},
    {:bg, 1, 7, 0}
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
            mosaic: 0,
            mosaic_start_line: 0,
            mosaic_reload_pending?: false,
            bg_sc: {0, 0, 0, 0},
            bg_name_base: {0, 0, 0, 0},
            bg_hofs: {0, 0, 0, 0},
            bg_vofs: {0, 0, 0, 0},
            scroll_latch: 0,
            bg_hofs_latch: 0,
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
            oam_internal_address: 0,
            oam_latch: 0,
            obj_priority_rotation?: false,
            obj_first: 0,
            oam_version: 0,
            vmain: 0,
            vmadd: 0,
            vram_read_buffer: 0,
            cgadd: 0,
            cgram_write_latch: 0,
            cgram_second_byte?: false,
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
            obj_interlace?: false,
            overscan?: false,
            pseudo_hires?: false,
            extbg?: false,
            interlace_field: 0,
            latched_hcounter: 0,
            latched_vcounter: 0,
            hcounter_second_byte?: false,
            vcounter_second_byte?: false,
            counter_latched?: false,
            ppu1_mdr: 0,
            ppu2_mdr: 0,
            obj_range_over?: false,
            obj_time_over?: false,
            obj_limit_cache_key: nil,
            obj_limit_rows: nil,
            frame_number: 0,
            frame_ready: nil,
            scanline_states: nil,
            raster_segments: %{},
            render_dirty?: true,
            vram_version: 0,
            vram_page_versions: List.duplicate(0, 256) |> List.to_tuple(),
            vram_block_versions: List.duplicate(0, 8) |> List.to_tuple(),
            cgram_version: 0,
            cached_render_key: nil,
            cached_frame_data: nil,
            cached_frame_width: nil,
            cached_frame_height: nil,
            rendered_frames: 0,
            reused_frames: 0,
            render_pipeline?: false,
            video_filter: :native,
            video_filter_options: [],
            render_task: nil

  @type frame :: %{
          number: non_neg_integer(),
          width: 256 | 602,
          height: 224 | 239,
          pixel_format: :rgb24,
          data: binary()
        }
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {video_filter, video_filter_options} =
      opts |> Keyword.get(:video_filter, :native) |> normalize_video_filter()

    validate_video_filter!(video_filter)

    %__MODULE__{
      cache_identity: make_ref(),
      render_pipeline?: Keyword.get(opts, :render_pipeline, false),
      video_filter: video_filter,
      video_filter_options: video_filter_options
    }
  end

  @doc "Selects the PPU presentation filter without changing emulated video state."
  def set_video_filter(ppu, filter) do
    {filter, options} = normalize_video_filter(filter)
    validate_video_filter!(filter)

    %{
      ppu
      | video_filter: filter,
        video_filter_options: options,
        cached_render_key: nil,
        cached_frame_data: nil,
        cached_frame_width: nil,
        cached_frame_height: nil,
        render_dirty?: true
    }
  end

  @doc "Returns presentation dimensions and pixel scale for SNES load options."
  def video_capabilities(options \\ []) do
    filter = Keyword.get(options, :video_filter, :native)
    {filter, _filter_options} = normalize_video_filter(filter)
    validate_video_filter!(filter)

    %{
      width: video_filter_width(filter),
      height: 224,
      pixel_scale: video_filter_pixel_scale(filter),
      pixel_formats: [:rgb24],
      frame_rate: 60.0988
    }
  end

  @doc false
  def write(ppu, 0x2104, value, access) do
    write_oam(ppu, value, ppu_memory_accessible?(ppu, access))
  end

  def write(ppu, register, value, access) when register in 0x2116..0x2117 do
    vmadd =
      if register == 0x2116,
        do: (ppu.vmadd &&& 0xFF00) ||| value,
        else: (ppu.vmadd &&& 0x00FF) ||| value <<< 8

    load_vram_read_buffer(%{ppu | vmadd: vmadd}, ppu_memory_accessible?(ppu, access))
  end

  def write(ppu, register, value, access) when register in 0x2118..0x2119 do
    byte = if register == 0x2118, do: :low, else: :high
    write_vram(ppu, byte, value, ppu_memory_accessible?(ppu, access))
  end

  def write(ppu, 0x2122, value, access) do
    write_cgram(ppu, value, cgram_accessible?(ppu, access))
  end

  def write(ppu, register, value, _access), do: write(ppu, register, value)

  @spec write(t(), 0x2100..0x213F, byte()) :: t()
  def write(ppu, 0x2100, value) do
    force_blank? = (value &&& 0x80) != 0
    brightness = value &&& 0x0F

    %{
      ppu
      | force_blank?: force_blank?,
        brightness: brightness,
        render_dirty?:
          ppu.render_dirty? or ppu.force_blank? != force_blank? or ppu.brightness != brightness
    }
  end

  def write(ppu, 0x2101, value), do: update_visual(ppu, %{obsel: value})

  def write(ppu, 0x2105, value),
    do:
      update_visual(ppu, %{
        bg_mode: value &&& 0x07,
        bg3_priority?: (value &&& 0x08) != 0,
        bg_tile_size: value >>> 4
      })

  def write(ppu, 0x2106, value) do
    changed? = ppu.mosaic != value

    %{
      ppu
      | mosaic: value,
        mosaic_reload_pending?: ppu.mosaic_reload_pending? or changed?,
        render_dirty?: ppu.render_dirty? or changed?
    }
  end

  def write(ppu, 0x2102, value) do
    oamadd = (ppu.oamadd &&& 0x100) ||| value
    reset_oam_address(ppu, oamadd, ppu.obj_priority_rotation?)
  end

  def write(ppu, 0x2103, value) do
    oamadd = (ppu.oamadd &&& 0x0FF) ||| (value &&& 1) <<< 8
    reset_oam_address(ppu, oamadd, (value &&& 0x80) != 0)
  end

  def write(ppu, 0x2104, value), do: write_oam(ppu, value, true)

  def write(ppu, register, value) when register in 0x2107..0x210A do
    bg = register - 0x2107
    bg_sc = put_elem(ppu.bg_sc, bg, value)
    %{ppu | bg_sc: bg_sc, render_dirty?: ppu.render_dirty? or ppu.bg_sc != bg_sc}
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
        scroll =
          (value <<< 8 ||| (ppu.scroll_latch &&& 0xF8) ||| (ppu.bg_hofs_latch &&& 0x07)) &&&
            0x03FF

        bg_hofs = put_elem(ppu.bg_hofs, bg, scroll)

        %{
          ppu
          | bg_hofs: bg_hofs,
            scroll_latch: value,
            bg_hofs_latch: value,
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

  def write(ppu, 0x2116, value) do
    load_vram_read_buffer(%{ppu | vmadd: (ppu.vmadd &&& 0xFF00) ||| value}, true)
  end

  def write(ppu, 0x2117, value) do
    load_vram_read_buffer(%{ppu | vmadd: (ppu.vmadd &&& 0x00FF) ||| value <<< 8}, true)
  end

  def write(ppu, 0x2118, value), do: write_vram(ppu, :low, value, true)
  def write(ppu, 0x2119, value), do: write_vram(ppu, :high, value, true)

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

  def write(ppu, 0x2121, value), do: %{ppu | cgadd: value, cgram_second_byte?: false}

  def write(ppu, 0x2122, value), do: write_cgram(ppu, value, true)

  def write(ppu, register, value) when register in 0x2123..0x2125 do
    update_visual(ppu, %{window_select: put_elem(ppu.window_select, register - 0x2123, value)})
  end

  def write(ppu, register, value) when register in 0x2126..0x2129 do
    window_positions = put_elem(ppu.window_positions, register - 0x2126, value)

    %{
      ppu
      | window_positions: window_positions,
        render_dirty?: ppu.render_dirty? or ppu.window_positions != window_positions
    }
  end

  def write(ppu, 0x212A, value),
    do: update_visual(ppu, %{window_logic: put_elem(ppu.window_logic, 0, value)})

  def write(ppu, 0x212B, value),
    do: update_visual(ppu, %{window_logic: put_elem(ppu.window_logic, 1, value)})

  def write(ppu, 0x212C, value) do
    value = value &&& 0x1F
    %{ppu | main_screen: value, render_dirty?: ppu.render_dirty? or ppu.main_screen != value}
  end

  def write(ppu, 0x212D, value) do
    value = value &&& 0x1F
    %{ppu | sub_screen: value, render_dirty?: ppu.render_dirty? or ppu.sub_screen != value}
  end

  def write(ppu, 0x212E, value) do
    value = value &&& 0x1F
    %{ppu | main_window: value, render_dirty?: ppu.render_dirty? or ppu.main_window != value}
  end

  def write(ppu, 0x212F, value) do
    value = value &&& 0x1F
    %{ppu | sub_window: value, render_dirty?: ppu.render_dirty? or ppu.sub_window != value}
  end

  def write(ppu, 0x2130, value),
    do: %{
      ppu
      | color_window_select: value,
        render_dirty?: ppu.render_dirty? or ppu.color_window_select != value
    }

  def write(ppu, 0x2131, value),
    do: %{ppu | color_math: value, render_dirty?: ppu.render_dirty? or ppu.color_math != value}

  def write(ppu, 0x2132, value) do
    component = value &&& 0x1F

    fixed_color =
      ppu.fixed_color
      |> set_color_component(0x001F, 0, component, (value &&& 0x20) != 0)
      |> set_color_component(0x03E0, 5, component, (value &&& 0x40) != 0)
      |> set_color_component(0x7C00, 10, component, (value &&& 0x80) != 0)

    %{
      ppu
      | fixed_color: fixed_color,
        render_dirty?: ppu.render_dirty? or ppu.fixed_color != fixed_color
    }
  end

  def write(ppu, 0x2133, value),
    do:
      update_visual(ppu, %{
        interlace?: (value &&& 0x01) != 0,
        obj_interlace?: (value &&& 0x02) != 0,
        overscan?: (value &&& 0x04) != 0,
        pseudo_hires?: (value &&& 0x08) != 0,
        extbg?: (value &&& 0x40) != 0
      })

  def write(ppu, _register, _value), do: ppu

  @doc false
  def read(ppu, 0x2138, open_bus, access) do
    value =
      if ppu_memory_accessible?(ppu, access),
        do: :array.get(oam_physical_address(ppu.oam_internal_address), ppu.oam),
        else: open_bus

    {value, set_oam_internal_address(ppu, ppu.oam_internal_address + 1 &&& 0x3FF)}
    |> latch_ppu1_mdr()
  end

  def read(ppu, register, _open_bus, access) when register in 0x2139..0x213A do
    byte = if register == 0x2139, do: :low, else: :high

    ppu
    |> read_vram(byte, ppu_memory_accessible?(ppu, access))
    |> latch_ppu1_mdr()
  end

  def read(ppu, 0x213B, open_bus, access) do
    ppu
    |> read_cgram(open_bus, cgram_accessible?(ppu, access))
    |> latch_ppu2_mdr()
  end

  def read(ppu, 0x2137, open_bus, %{counter_latch_enabled?: true} = access) do
    {open_bus, latch_counters(ppu, div(access.hclock, 4), access.vline)}
  end

  def read(ppu, 0x213E, _open_bus, _access), do: read_stat77(ppu)

  def read(ppu, 0x213F, _open_bus, access) do
    read_stat78(ppu, access.region, access.field, access.counter_latch_enabled?)
  end

  def read(ppu, register, open_bus, _access), do: read(ppu, register, open_bus)

  @spec read(t(), 0x2100..0x213F, byte()) :: {byte(), t()}
  def read(ppu, 0x2138, _open_bus) do
    value = :array.get(oam_physical_address(ppu.oam_internal_address), ppu.oam)

    {value, set_oam_internal_address(ppu, ppu.oam_internal_address + 1 &&& 0x3FF)}
    |> latch_ppu1_mdr()
  end

  def read(ppu, 0x2139, _open_bus), do: ppu |> read_vram(:low, true) |> latch_ppu1_mdr()
  def read(ppu, 0x213A, _open_bus), do: ppu |> read_vram(:high, true) |> latch_ppu1_mdr()

  def read(ppu, 0x213B, open_bus),
    do: ppu |> read_cgram(open_bus, true) |> latch_ppu2_mdr()

  def read(ppu, register, _open_bus) when register in 0x2134..0x2136 do
    value = ppu.m7_product >>> ((register - 0x2134) * 8) &&& 0xFF
    {value, %{ppu | ppu1_mdr: value}}
  end

  def read(%{hcounter_second_byte?: false} = ppu, 0x213C, _open_bus) do
    value = ppu.latched_hcounter &&& 0xFF
    {value, %{ppu | hcounter_second_byte?: true, ppu2_mdr: value}}
  end

  def read(ppu, 0x213C, _open_bus) do
    value = (ppu.ppu2_mdr &&& 0xFE) ||| (ppu.latched_hcounter >>> 8 &&& 1)
    {value, %{ppu | hcounter_second_byte?: false, ppu2_mdr: value}}
  end

  def read(%{vcounter_second_byte?: false} = ppu, 0x213D, _open_bus) do
    value = ppu.latched_vcounter &&& 0xFF
    {value, %{ppu | vcounter_second_byte?: true, ppu2_mdr: value}}
  end

  def read(ppu, 0x213D, _open_bus) do
    value = (ppu.ppu2_mdr &&& 0xFE) ||| (ppu.latched_vcounter >>> 8 &&& 1)
    {value, %{ppu | vcounter_second_byte?: false, ppu2_mdr: value}}
  end

  def read(ppu, 0x213E, _open_bus), do: read_stat77(ppu)

  def read(ppu, 0x213F, _open_bus),
    do: read_stat78(ppu, :ntsc, ppu.interlace_field, true)

  def read(ppu, register, _open_bus) when register in @ppu1_mdr_read_registers,
    do: {ppu.ppu1_mdr, ppu}

  def read(ppu, _register, open_bus), do: {open_bus, ppu}

  @doc false
  def latch_counters(ppu, hcounter, vcounter) do
    %{
      ppu
      | latched_hcounter: hcounter &&& 0x1FF,
        latched_vcounter: vcounter &&& 0x1FF,
        counter_latched?: true
    }
  end

  @doc "Completes a frame at the first vblank scanline."
  @spec enter_scanline(t(), non_neg_integer()) :: t()
  def enter_scanline(%__MODULE__{} = ppu, line) do
    ppu = accumulate_obj_overflow(ppu, line)

    if line == vblank_start(ppu) do
      {frame, ppu} =
        if ppu.render_pipeline? do
          ppu = finish_render_task(ppu)
          {ppu.frame_ready, start_render_task(%{ppu | frame_ready: nil})}
        else
          render_or_reuse_frame(ppu)
        end

      ppu =
        if ppu.force_blank?,
          do: ppu,
          else: set_oam_internal_address(ppu, ppu.oamadd <<< 1)

      %{ppu | frame_ready: frame, frame_number: ppu.frame_number + 1}
    else
      ppu
    end
  end

  @doc false
  def begin_frame(ppu, capture_scanlines?),
    do: begin_frame(ppu, capture_scanlines?, ppu.interlace_field)

  @doc false
  def begin_frame(ppu, capture_scanlines?, field) when field in [0, 1] do
    %{
      ppu
      | mosaic_start_line: 0,
        mosaic_reload_pending?: false,
        interlace_field: field,
        obj_range_over?: false,
        obj_time_over?: false,
        scanline_states: if(capture_scanlines?, do: [], else: nil),
        raster_segments: %{}
    }
  end

  @doc false
  def enable_scanline_capture(%{scanline_states: nil} = ppu, completed_lines)
      when is_integer(completed_lines) and completed_lines >= 0 do
    %{ppu | scanline_states: List.duplicate(visual_state(ppu), completed_lines)}
  end

  def enable_scanline_capture(ppu, _completed_lines), do: ppu

  @doc false
  def capture_scanline(%{scanline_states: states} = ppu, line)
      when is_list(states) and line >= 1 do
    if line < vblank_start(ppu) do
      ppu = reload_mosaic_for_scanline(ppu, line - 1)
      %{ppu | scanline_states: [visual_state(ppu) | states]}
    else
      ppu
    end
  end

  def capture_scanline(ppu, _line), do: ppu

  @doc false
  def capture_raster_change(previous_ppu, ppu, line, hclock)
      when is_integer(line) and line >= 1 and is_integer(hclock) do
    screen_line = line - 1
    x = min(max(div(hclock - @active_display_start, 4), 0), @width)

    if x == @width do
      ppu
    else
      previous_state = visual_state(previous_ppu)
      state = visual_state(ppu)
      initial_segments = if x == 0, do: [{0, state}], else: [{0, previous_state}, {x, state}]

      segments =
        Map.update(ppu.raster_segments, screen_line, initial_segments, fn segments ->
          case List.last(segments) do
            {^x, _previous_state} -> List.replace_at(segments, -1, {x, state})
            _other -> segments ++ [{x, state}]
          end
        end)

      %{ppu | raster_segments: segments}
    end
  end

  def capture_raster_change(_previous_ppu, ppu, _line, _hclock), do: ppu

  @spec take_frame(t()) :: {frame() | nil, t()}
  def take_frame(%__MODULE__{frame_ready: frame} = ppu),
    do: {frame, %{ppu | frame_ready: nil}}

  @spec render_frame(t()) :: frame()
  def render_frame(%__MODULE__{} = ppu) do
    height = if ppu.overscan?, do: 239, else: 224
    scanlines = scanline_states(ppu, height)

    data =
      cond do
        is_nil(scanlines) and (ppu.force_blank? or ppu.brightness == 0) ->
          :binary.copy(<<0, 0, 0>>, @width * height)

        nx_renderer?(ppu) ->
          Beamicom.SNES.Nx.PPURenderer.render(ppu, nx_object_descriptors(ppu, height))

        true ->
          palette = palette(ppu)
          color_data = color_data(palette, ppu.brightness)

          render_ppu = %{
            ppu
            | vram: ppu.vram |> :array.to_list() |> :erlang.list_to_binary(),
              oam: ppu.oam |> :array.to_list() |> :erlang.list_to_binary()
          }

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

    {width, data} = apply_video_filter(ppu, data)

    %{
      number: ppu.frame_number,
      width: width,
      height: height,
      pixel_format: :rgb24,
      data: data
    }
  end

  defp nx_renderer?(ppu) do
    map_size(ppu.raster_segments) == 0 and not mosaic_active?(ppu) and
      Application.get_env(:beamicom_snes, :ppu_renderer, :native) == :nx and
      Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) and
      Beamicom.SNES.Nx.PPURenderer.supported?(ppu)
  end

  defp apply_video_filter(%{video_filter: :native}, data), do: {@width, data}

  defp apply_video_filter(ppu, data) do
    state = ppu.video_filter.prepare(ppu.video_filter_options)
    filtered = ppu.video_filter.filter(data, ppu.frame_number, state)
    {video_filter_width(ppu.video_filter), filtered}
  end

  defp normalize_video_filter({filter, options}) when is_atom(filter) and is_list(options),
    do: {filter, options}

  defp normalize_video_filter(:native), do: {:native, []}
  defp normalize_video_filter(filter) when is_atom(filter), do: {filter, []}

  defp validate_video_filter!(:native), do: :ok

  defp validate_video_filter!(filter) do
    if Code.ensure_loaded?(filter),
      do: :ok,
      else: raise(ArgumentError, "invalid SNES video filter: #{inspect(filter)}")
  end

  defp video_filter_width(:native), do: @width
  defp video_filter_width(filter), do: filter.output_width()

  defp video_filter_pixel_scale(:native), do: {1, 1}

  defp video_filter_pixel_scale(filter), do: filter.pixel_scale()

  defp nx_object_descriptors(ppu, height) do
    scanlines = scanline_states(ppu, height)

    obsel_key =
      if scanlines,
        do: 0..(height - 1) |> Enum.map(&elem(elem(scanlines, &1), 9)) |> List.to_tuple(),
        else: ppu.obsel

    object_state_key =
      if scanlines,
        do:
          0..(height - 1) |> Enum.map(&visual_obj_state(elem(scanlines, &1))) |> List.to_tuple(),
        else: obj_state(ppu)

    cache_key = {ppu.cache_identity, ppu.oam_version, obsel_key, object_state_key}

    process_key = {__MODULE__, :nx_object_descriptors}

    case Process.get(process_key) do
      {^cache_key, descriptors} ->
        descriptors

      _other ->
        descriptors = build_nx_object_descriptors(ppu, height, scanlines)
        Process.put(process_key, {cache_key, descriptors})
        descriptors
    end
  end

  defp build_nx_object_descriptors(ppu, height, scanlines) do
    object_ppu = %{
      ppu
      | oam: ppu.oam |> :array.to_list() |> :erlang.list_to_binary()
    }

    rows =
      if scanlines do
        {rows, _cache} =
          Enum.map_reduce(0..(height - 1), %{}, fn y, cache ->
            row_ppu = apply_visual_state(object_ppu, elem(scanlines, y))
            {sprites, cache} = cached_obj_sprites(row_ppu, cache)
            selected = select_obj_sprites(row_ppu, sprites, y)
            {object_descriptor_row(row_ppu, selected), cache}
          end)

        rows
      else
        selected_rows =
          object_ppu |> parse_obj_sprites() |> bucket_obj_sprites(object_ppu, height)

        for y <- 0..(height - 1) do
          object_descriptor_row(object_ppu, Map.get(selected_rows, y, {0, []}) |> elem(1))
        end
      end

    {:descriptors, IO.iodata_to_binary(rows)}
  end

  defp object_descriptor_row(ppu, selected) do
    descriptors = Enum.map(selected, &object_descriptor(ppu, &1))
    [descriptors, :binary.copy(@empty_object_descriptor, 32 - length(descriptors))]
  end

  defp object_descriptor(ppu, {x, row, {width, height}, tile, attributes}) do
    source_y = obj_source_y(ppu, row, {width, height}, attributes)
    priority = (attributes >>> 4 &&& 0x03) + 1
    palette_base = 128 + (attributes >>> 1 &&& 0x07) * 16
    name_offset = if (attributes &&& 1) != 0, do: ((ppu.obsel >>> 3 &&& 3) + 1) * 0x2000, else: 0
    base = (ppu.obsel &&& 0x07) * 0x4000 + name_offset

    hflip = if((attributes &&& 0x40) != 0, do: 1, else: 0)

    <<1::signed-native-32, x::signed-native-32, width::signed-native-32, tile::signed-native-32,
      source_y::signed-native-32, priority::signed-native-32, palette_base::signed-native-32,
      base::signed-native-32, hflip::signed-native-32>>
  end

  defp bucket_obj_sprites(sprites, ppu, height) do
    Enum.reduce(sprites, %{}, fn {x, y, {_width, sprite_height} = dimensions, tile, attributes},
                                 rows ->
      Enum.reduce(0..(obj_visible_height(ppu, sprite_height) - 1), rows, fn row, rows ->
        screen_y = y + row &&& 0xFF

        if screen_y < height do
          {count, selected} = Map.get(rows, screen_y, {0, []})

          if count < 32,
            do:
              Map.put(
                rows,
                screen_y,
                {count + 1, [{x, row, dimensions, tile, attributes} | selected]}
              ),
            else: rows
        else
          rows
        end
      end)
    end)
  end

  defp render_rows(rows, render_ppu, scanlines, palette, color_data) do
    rows
    |> Enum.map_reduce({%{}, %{}, %{}}, fn y, caches ->
      row_ppu =
        if scanlines, do: apply_visual_state(render_ppu, elem(scanlines, y)), else: render_ppu

      case Map.get(render_ppu.raster_segments, y) do
        nil -> render_visual_row(row_ppu, y, not is_nil(scanlines), palette, color_data, caches)
        segments -> render_raster_row(render_ppu, segments, y, palette, color_data, caches)
      end
    end)
    |> elem(0)
  end

  defp render_raster_row(render_ppu, segments, y, palette, color_data, caches) do
    spans =
      segments
      |> Enum.zip(tl(segments) ++ [{@width, nil}])
      |> Enum.filter(fn {{first, _state}, {last, _next_state}} -> first < last end)

    spans
    |> Enum.map_reduce(caches, fn {{first, state}, {last, _next_state}}, caches ->
      row_ppu = apply_visual_state(render_ppu, state)
      {row, caches} = render_visual_row(row_ppu, y, true, palette, color_data, caches)
      {binary_part(row, first * 3, (last - first) * 3), caches}
    end)
    |> then(fn {parts, caches} -> {IO.iodata_to_binary(parts), caches} end)
  end

  defp render_visual_row(
         row_ppu,
         y,
         dynamic_colors?,
         palette,
         color_data,
         {tile_cache, color_cache, obj_cache}
       ) do
    if row_ppu.force_blank? or row_ppu.brightness == 0 do
      {:binary.copy(<<0, 0, 0>>, @width), {tile_cache, color_cache, obj_cache}}
    else
      main_layers = render_layers(row_ppu, row_ppu.main_screen)
      sub_layers = render_layers(row_ppu, row_ppu.sub_screen)

      {row_palette, row_color_data, color_cache} =
        if dynamic_colors? do
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
    end
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
          main = layer_pixel_unmasked(ppu, bg_rows, obj_row, x, main_layers, :main)
          sub = layer_pixel_unmasked(ppu, bg_rows, obj_row, x, sub_layers, :sub)
          render_output_color(ppu, palette, rgb_palette, components, main, sub, x)
        end
      else
        for x <- 0..(@width - 1), into: <<>> do
          main =
            layer_pixel(ppu, bg_rows, obj_row, x, main_layers, ppu.main_window, :main)

          sub = layer_pixel(ppu, bg_rows, obj_row, x, sub_layers, ppu.sub_window, :sub)
          render_output_color(ppu, palette, rgb_palette, components, main, sub, x)
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

  defp render_layers(%{bg_mode: 2}, screen), do: enabled_layers(@mode2_layers, screen)
  defp render_layers(%{bg_mode: 3}, screen), do: enabled_layers(@mode3_layers, screen)
  defp render_layers(%{bg_mode: 4}, screen), do: enabled_layers(@mode4_layers, screen)
  defp render_layers(%{bg_mode: 5}, screen), do: enabled_layers(@mode5_layers, screen)
  defp render_layers(%{bg_mode: 6}, screen), do: enabled_layers(@mode6_layers, screen)

  defp render_layers(%{bg_mode: 7, extbg?: true}, screen),
    do: enabled_layers(@mode7_extbg_layers, screen)

  defp render_layers(%{bg_mode: 7}, screen), do: enabled_layers(@mode7_layers, screen)

  defp enabled_layers(layers, screen),
    do:
      Enum.filter(layers, fn
        {:bg, bg, _bpp, _priority} -> (screen &&& 1 <<< bg) != 0
        {:obj, _priority} -> (screen &&& 0x10) != 0
      end)

  defp layer_pixel(_ppu, _bg_rows, _obj_row, _x, [], _window_mask, _screen),
    do: {:backdrop, 0}

  defp layer_pixel(
         ppu,
         bg_rows,
         obj_row,
         x,
         [{:bg, bg, _bpp, priority} | rest],
         mask,
         screen
       ) do
    masked? = (mask &&& 1 <<< bg) != 0 and window_masked?(ppu, bg, x)

    {row, _priorities} = elem(bg_rows, bg)
    sample_x = background_sample_x(ppu, x, screen)

    case elem(row, sample_x) do
      {^priority, color} when color != 0 and not masked? -> {bg, color}
      _transparent -> layer_pixel(ppu, bg_rows, obj_row, x, rest, mask, screen)
    end
  end

  defp layer_pixel(ppu, bg_rows, obj_row, x, [{:obj, priority} | rest], mask, screen) do
    masked? = (mask &&& 0x10) != 0 and window_masked?(ppu, :obj, x)

    case Map.get(obj_row, x) do
      {^priority, color} when not masked? -> {:obj, color}
      _transparent -> layer_pixel(ppu, bg_rows, obj_row, x, rest, mask, screen)
    end
  end

  defp layer_pixel_unmasked(_ppu, _bg_rows, _obj_row, _x, [], _screen),
    do: {:backdrop, 0}

  defp layer_pixel_unmasked(
         ppu,
         bg_rows,
         obj_row,
         x,
         [{:bg, bg, _bpp, priority} | rest],
         screen
       ) do
    {row, _priorities} = elem(bg_rows, bg)
    sample_x = background_sample_x(ppu, x, screen)

    case elem(row, sample_x) do
      {^priority, color} when color != 0 -> {bg, color}
      _transparent -> layer_pixel_unmasked(ppu, bg_rows, obj_row, x, rest, screen)
    end
  end

  defp layer_pixel_unmasked(ppu, bg_rows, obj_row, x, [{:obj, priority} | rest], screen) do
    case Map.get(obj_row, x) do
      {^priority, color} -> {:obj, color}
      _transparent -> layer_pixel_unmasked(ppu, bg_rows, obj_row, x, rest, screen)
    end
  end

  defp background_sample_x(%{bg_mode: mode}, x, :main) when mode in [5, 6],
    do: x * 2 + 1

  defp background_sample_x(%{bg_mode: mode}, x, :sub) when mode in [5, 6], do: x * 2
  defp background_sample_x(_ppu, x, _screen), do: x

  defp active_layers(layers, bg_rows, obj_priorities) do
    Enum.filter(layers, fn
      {:bg, bg, _bpp, priority} ->
        {_row, priorities} = elem(bg_rows, bg)
        (priorities &&& 1 <<< priority) != 0

      {:obj, priority} ->
        (obj_priorities &&& 1 <<< priority) != 0
    end)
  end

  defp render_output_color(ppu, palette, rgb_palette, components, main, sub, x) do
    main_rgb = render_color(ppu, palette, rgb_palette, components, main, sub, x)

    if ppu.pseudo_hires? or ppu.bg_mode in [5, 6] do
      {sub_layer, sub_index} = sub

      sub_rgb =
        ppu
        |> palette_color(palette, sub_layer, sub_index)
        |> color_to_rgb(components)

      average_rgb(main_rgb, sub_rgb)
    else
      main_rgb
    end
  end

  defp average_rgb(<<r1, g1, b1>>, <<r2, g2, b2>>),
    do: <<div(r1 + r2, 2), div(g1 + g2, 2), div(b1 + b2, 2)>>

  defp render_color(
         %{color_window_select: select} = ppu,
         palette,
         rgb_palette,
         components,
         {layer, main_index},
         {sub_layer, sub_index},
         _x
       )
       when (select &&& 0xF0) == 0 do
    main = palette_color(ppu, palette, layer, main_index)

    if color_math_enabled?(ppu.color_math, layer, main_index) do
      {second, math} = color_math_operand(ppu, palette, sub_layer, sub_index)
      color_to_rgb(blend_color(main, second, math), components)
    else
      if direct_color?(ppu, layer),
        do: color_to_rgb(main, components),
        else: elem(rgb_palette, main_index &&& 0xFF)
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
    math? = color_math_enabled?(ppu.color_math, layer, main_index)
    clipped? = window_mode_applies?(clip_mode, color_window?)

    main =
      if clipped?,
        do: 0,
        else: palette_color(ppu, palette, layer, main_index)

    color =
      if math? and not window_mode_applies?(prevent_mode, color_window?) do
        {second, math} = color_math_operand(ppu, palette, sub_layer, sub_index)
        blend_color(main, second, math)
      else
        main
      end

    if color == main and not math? and not clipped? and not direct_color?(ppu, layer),
      do: elem(rgb_palette, main_index &&& 0xFF),
      else: color_to_rgb(color, components)
  end

  defp palette_color(ppu, palette, layer, index) when ppu.bg_mode == 7 and layer == 0 do
    if direct_color?(ppu, layer),
      do: direct_color(index, 0),
      else: elem(palette, index &&& 0xFF)
  end

  defp palette_color(ppu, palette, layer, index)
       when ppu.bg_mode in [3, 4] and layer == 0 do
    if direct_color?(ppu, layer),
      do: direct_color(index, index >>> 8),
      else: elem(palette, index &&& 0xFF)
  end

  defp palette_color(_ppu, palette, _layer, index), do: elem(palette, index &&& 0xFF)

  defp color_math_operand(ppu, palette, sub_layer, sub_index) do
    cond do
      (ppu.color_window_select &&& 0x02) == 0 ->
        {ppu.fixed_color, ppu.color_math}

      sub_layer == :backdrop ->
        # With add/sub-screen selected, an uncovered sub-screen pixel falls
        # back to COLDATA. Hardware also disables CGADSUB's half operation for
        # this fallback; it is not the same case as explicitly selecting the
        # fixed-color operand with CGWSEL bit 1 clear.
        {ppu.fixed_color, ppu.color_math &&& bnot(0x40)}

      true ->
        {palette_color(ppu, palette, sub_layer, sub_index), ppu.color_math}
    end
  end

  defp direct_color?(%{bg_mode: 7, color_window_select: select}, 0), do: (select &&& 1) != 0

  defp direct_color?(%{bg_mode: mode, color_window_select: select}, 0)
       when mode in [3, 4],
       do: (select &&& 1) != 0

  defp direct_color?(_ppu, _layer), do: false

  defp direct_color(index, palette) do
    (index &&& 0x07) <<< 2 ||| (palette &&& 0x01) <<< 1 |||
      (index &&& 0x38) <<< 4 ||| (palette &&& 0x02) <<< 5 |||
      (index &&& 0xC0) <<< 7 ||| (palette &&& 0x04) <<< 10
  end

  defp window_mode_applies?(0, _inside?), do: false
  defp window_mode_applies?(1, inside?), do: not inside?
  defp window_mode_applies?(2, inside?), do: inside?
  defp window_mode_applies?(3, _inside?), do: true

  defp window_masked?(ppu, layer, x) do
    {config, logic} = window_config(ppu, layer)
    {w1_left, w1_right, w2_left, w2_right} = ppu.window_positions
    # Each window selector pair is encoded as enable,invert (EIei): the high
    # bit enables the window and the low bit inverts its area.
    w1? = (config &&& 0x02) != 0
    w2? = (config &&& 0x08) != 0
    w1 = window_value(x, w1_left, w1_right, (config &&& 0x01) != 0)
    w2 = window_value(x, w2_left, w2_right, (config &&& 0x04) != 0)

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

  defp color_math_enabled?(math, :backdrop, _index), do: (math &&& 0x20) != 0
  defp color_math_enabled?(math, :obj, index), do: (math &&& 0x10) != 0 and index >= 0xC0
  defp color_math_enabled?(math, bg, _index), do: (math &&& 1 <<< bg) != 0

  defp blend_color(first, second, math) do
    subtract? = (math &&& 0x80) != 0
    half? = (math &&& 0x40) != 0

    red = blend_component(first &&& 0x1F, second &&& 0x1F, subtract?, half?)

    green =
      blend_component(first >>> 5 &&& 0x1F, second >>> 5 &&& 0x1F, subtract?, half?)

    blue =
      blend_component(first >>> 10 &&& 0x1F, second >>> 10 &&& 0x1F, subtract?, half?)

    red ||| green <<< 5 ||| blue <<< 10
  end

  defp blend_component(first, second, true, half?) do
    value = max(first - second, 0)
    if half?, do: value >>> 1, else: value
  end

  defp blend_component(first, second, false, half?) do
    value = first + second
    if half?, do: value >>> 1, else: min(value, 31)
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
    key = obj_state(ppu)

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

    indices =
      if ppu.obj_priority_rotation? do
        first = ppu.obj_first
        Enum.to_list(first..127) ++ if(first == 0, do: [], else: Enum.to_list(0..(first - 1)))
      else
        0..127
      end

    for index <- indices do
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
    |> then(&select_obj_sprites(ppu, &1, screen_y))
    |> then(&render_selected_obj_row(ppu, &1))
  end

  defp select_obj_sprites(ppu, parsed_sprites, screen_y) do
    parsed_sprites
    |> Enum.reduce_while(
      {[], 0},
      fn {x, y, {_width, height} = dimensions, tile, attributes}, {sprites, count} ->
        row = screen_y - y &&& 0xFF

        if row < obj_visible_height(ppu, height) do
          sprites = [{x, row, dimensions, tile, attributes} | sprites]
          count = count + 1

          if count == 32, do: {:halt, {sprites, count}}, else: {:cont, {sprites, count}}
        else
          {:cont, {sprites, count}}
        end
      end
    )
    |> elem(0)
  end

  defp render_selected_obj_row(ppu, sprites) do
    pixels =
      Enum.reduce(sprites, %{}, fn {x, row, dimensions, tile, attributes}, pixels ->
        render_obj_sprite_row(ppu, pixels, x, row, dimensions, tile, attributes)
      end)

    priorities =
      Enum.reduce(pixels, 0, fn {_x, {priority, _color}}, mask -> mask ||| 1 <<< priority end)

    {pixels, priorities}
  end

  defp render_obj_sprite_row(_ppu, pixels, x, _row, {width, _height}, _tile, _attributes)
       when x >= @width or x + width <= 0,
       do: pixels

  defp render_obj_sprite_row(ppu, pixels, x, row, {width, height}, tile, attributes) do
    hflip? = (attributes &&& 0x40) != 0
    source_y = obj_source_y(ppu, row, {width, height}, attributes)
    priority = attributes >>> 4 &&& 0x03
    palette_base = 128 + (attributes >>> 1 &&& 0x07) * 16
    name_offset = if (attributes &&& 1) != 0, do: ((ppu.obsel >>> 3 &&& 3) + 1) * 0x2000, else: 0
    base = (ppu.obsel &&& 0x07) * 0x4000 + name_offset

    render_obj_tiles(
      ppu.vram,
      pixels,
      x,
      width,
      tile,
      source_y,
      hflip?,
      priority,
      palette_base,
      base,
      0
    )
  end

  defp render_obj_tiles(
         _vram,
         pixels,
         _x,
         width,
         _tile,
         _source_y,
         _hflip?,
         _priority,
         _palette_base,
         _base,
         output_start
       )
       when output_start >= width,
       do: pixels

  defp render_obj_tiles(
         vram,
         pixels,
         x,
         width,
         tile,
         source_y,
         hflip?,
         priority,
         palette_base,
         base,
         output_start
       ) do
    first_source_x = if hflip?, do: width - 1 - output_start, else: output_start
    obj_tile = obj_tile_number(tile, div(first_source_x, 8), div(source_y, 8))
    address = base + obj_tile * 32 + (source_y &&& 7) * 2

    pixels =
      render_obj_tile_pixels(
        pixels,
        x,
        width,
        hflip?,
        priority,
        palette_base,
        output_start,
        0,
        vram_byte(vram, address),
        vram_byte(vram, address + 1),
        vram_byte(vram, address + 16),
        vram_byte(vram, address + 17)
      )

    render_obj_tiles(
      vram,
      pixels,
      x,
      width,
      tile,
      source_y,
      hflip?,
      priority,
      palette_base,
      base,
      output_start + 8
    )
  end

  defp render_obj_tile_pixels(
         pixels,
         _x,
         _width,
         _hflip?,
         _priority,
         _palette_base,
         _output_start,
         8,
         _plane0,
         _plane1,
         _plane2,
         _plane3
       ),
       do: pixels

  defp render_obj_tile_pixels(
         pixels,
         x,
         width,
         hflip?,
         priority,
         palette_base,
         output_start,
         tile_x,
         plane0,
         plane1,
         plane2,
         plane3
       ) do
    output_x = output_start + tile_x
    screen_x = x + output_x

    pixels =
      if screen_x in 0..255 do
        source_x = if hflip?, do: width - 1 - output_x, else: output_x
        bit = 7 - (source_x &&& 7)

        color =
          (plane0 >>> bit &&& 1) |||
            (plane1 >>> bit &&& 1) <<< 1 |||
            (plane2 >>> bit &&& 1) <<< 2 |||
            (plane3 >>> bit &&& 1) <<< 3

        if color == 0,
          do: pixels,
          else: Map.put(pixels, screen_x, {priority, palette_base + color})
      else
        pixels
      end

    render_obj_tile_pixels(
      pixels,
      x,
      width,
      hflip?,
      priority,
      palette_base,
      output_start,
      tile_x + 1,
      plane0,
      plane1,
      plane2,
      plane3
    )
  end

  defp obj_sizes(0), do: {{8, 8}, {16, 16}}
  defp obj_sizes(1), do: {{8, 8}, {32, 32}}
  defp obj_sizes(2), do: {{8, 8}, {64, 64}}
  defp obj_sizes(3), do: {{16, 16}, {32, 32}}
  defp obj_sizes(4), do: {{16, 16}, {64, 64}}
  defp obj_sizes(5), do: {{32, 32}, {64, 64}}
  defp obj_sizes(6), do: {{16, 32}, {32, 64}}
  defp obj_sizes(7), do: {{16, 32}, {32, 32}}

  defp obj_visible_height(%{obj_interlace?: true}, height), do: height >>> 1
  defp obj_visible_height(_ppu, height), do: height

  defp accumulate_obj_overflow(
         %{force_blank?: false, obj_range_over?: range_over?, obj_time_over?: time_over?} = ppu,
         line
       )
       when line >= 1 do
    if line <= vblank_start(ppu) and not (range_over? and time_over?) do
      {rows, ppu} = obj_limit_rows(ppu)
      {sprite_count, sliver_count} = elem(rows, line - 1)

      %{
        ppu
        | obj_range_over?: range_over? or sprite_count > 32,
          obj_time_over?: time_over? or sliver_count > 34
      }
    else
      ppu
    end
  end

  defp accumulate_obj_overflow(ppu, _line), do: ppu

  defp obj_limit_rows(ppu) do
    key = {
      ppu.oam_version,
      ppu.obsel,
      ppu.obj_priority_rotation?,
      ppu.obj_first,
      ppu.obj_interlace?,
      ppu.interlace_field,
      ppu.overscan?
    }

    if ppu.obj_limit_cache_key == key and is_tuple(ppu.obj_limit_rows) do
      {ppu.obj_limit_rows, ppu}
    else
      rows = build_obj_limit_rows(ppu)
      {rows, %{ppu | obj_limit_cache_key: key, obj_limit_rows: rows}}
    end
  end

  defp build_obj_limit_rows(ppu) do
    {small_size, large_size} = obj_sizes(ppu.obsel >>> 5)
    first = if ppu.obj_priority_rotation?, do: ppu.obj_first, else: 0
    row_count = vblank_start(ppu)

    rows =
      Enum.reduce(0..127, %{}, fn offset_from_first, rows ->
        index = first + offset_from_first &&& 0x7F
        offset = index * 4
        high = :array.get(512 + div(index, 4), ppu.oam) >>> (rem(index, 4) * 2)
        raw_x = :array.get(offset, ppu.oam) ||| (high &&& 1) <<< 8
        y = :array.get(offset + 1, ppu.oam)
        dimensions = if((high &&& 2) != 0, do: large_size, else: small_size)

        add_obj_limit_rows(ppu, rows, raw_x, y, dimensions, row_count)
      end)

    0..(row_count - 1)
    |> Enum.map(&Map.get(rows, &1, {0, 0}))
    |> List.to_tuple()
  end

  defp add_obj_limit_rows(ppu, rows, raw_x, y, {width, height}, row_count) do
    if raw_x > 256 and raw_x + width - 1 < 512 do
      rows
    else
      slivers = obj_sliver_count({raw_x, {width, height}})

      Enum.reduce(0..(obj_visible_height(ppu, height) - 1), rows, fn sprite_row, rows ->
        screen_y = y + sprite_row &&& 0xFF

        if screen_y < row_count do
          Map.update(rows, screen_y, {1, slivers}, fn {sprite_count, sliver_count} ->
            added_slivers = if sprite_count < 32, do: slivers, else: 0
            {sprite_count + 1, sliver_count + added_slivers}
          end)
        else
          rows
        end
      end)
    end
  end

  defp obj_sliver_count({raw_x, {width, _height}}) do
    Enum.count(0..(div(width, 8) - 1), fn tile_x ->
      sliver_x = raw_x + tile_x * 8 &&& 0x1FF
      raw_x == 256 or sliver_x < 256 or sliver_x + 7 >= 512
    end)
  end

  defp obj_source_y(ppu, row, {width, height}, attributes) do
    interlaced_row = if ppu.obj_interlace?, do: row <<< 1, else: row
    vflip? = (attributes &&& 0x80) != 0

    source_y =
      cond do
        not vflip? -> interlaced_row
        not ppu.obj_interlace? -> height - 1 - interlaced_row
        width == height -> height - 1 - interlaced_row
        interlaced_row < width -> width - 1 - interlaced_row
        true -> width + width - 1 - (interlaced_row - width)
      end

    if ppu.obj_interlace? do
      source_y + if(vflip?, do: -ppu.interlace_field, else: ppu.interlace_field) &&& 0xFF
    else
      source_y
    end
  end

  # OBJ character numbers are an 8-bit {row, column} coordinate. Horizontal
  # traversal wraps the low nibble instead of carrying into the next tile row.
  # This matters for large sprites whose first character is not row-aligned.
  defp obj_tile_number(tile, tile_x, tile_y),
    do: ((tile &&& 0xF0) + tile_y * 16 ||| (tile + tile_x &&& 0x0F)) &&& 0xFF

  defp render_bg_row(ppu, bg, bpp, screen_y, tile_cache) when bpp in [2, 4, 8] do
    screen_y = mosaic_coordinate(ppu, bg, :vertical, screen_y)
    screen_y = interlaced_bg_coordinate(ppu, bg, screen_y + 1)
    hires? = ppu.bg_mode in [5, 6]
    output_width = if hires?, do: @width * 2, else: @width
    x = elem(ppu.bg_hofs, bg) <<< if(hires?, do: 1, else: 0) &&& 0x07FF
    y = screen_y + elem(ppu.bg_vofs, bg) &&& 0x03FF
    large_tiles? = (ppu.bg_tile_size &&& 1 <<< bg) != 0
    tile_height = if large_tiles?, do: 16, else: 8
    tile_width = if hires?, do: 16, else: tile_height

    {pixels, tile_cache} =
      if ppu.bg_mode in [2, 4, 6] do
        render_offset_bg_row(
          ppu,
          bg,
          bpp,
          screen_y,
          output_width,
          tile_width,
          tile_height,
          tile_cache
        )
      else
        tile_y = div(y, tile_height)
        first_tile = div(x, tile_width)
        skip = rem(x, tile_width)
        tile_count = div(skip + output_width + tile_width - 1, tile_width)

        {tiles, tile_cache} =
          0..(tile_count - 1)
          |> Enum.map_reduce(tile_cache, fn offset, tile_cache ->
            bg_tile_pixels(
              ppu,
              bg,
              bpp,
              first_tile + offset,
              tile_y,
              y,
              tile_width,
              tile_height,
              tile_cache
            )
          end)

        pixels = tiles |> List.flatten() |> Enum.drop(skip) |> Enum.take(output_width)
        {pixels, tile_cache}
      end

    pixels = apply_horizontal_mosaic(pixels, ppu, bg)

    priorities =
      Enum.reduce(pixels, 0, fn
        {_priority, 0}, mask -> mask
        {priority, _color}, mask -> mask ||| 1 <<< priority
      end)

    {List.to_tuple(pixels), priorities, tile_cache}
  end

  defp render_bg_row(%{bg_mode: 7} = ppu, bg, 7, screen_y, tile_cache)
       when bg in [0, 1] do
    a = signed16(ppu.m7a)
    b = signed16(ppu.m7b)
    c = signed16(ppu.m7c)
    d = signed16(ppu.m7d)
    center_x = signed13(ppu.m7x)
    center_y = signed13(ppu.m7y)
    hofs = signed13(ppu.m7hofs)
    vofs = signed13(ppu.m7vofs)
    screen_y = mosaic_coordinate(ppu, bg, :vertical, screen_y)
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

        if bg == 0,
          do: {0, color},
          else: {color >>> 7, color &&& 0x7F}
      end

    pixels = apply_horizontal_mosaic(pixels, ppu, bg)

    priorities =
      Enum.reduce(pixels, 0, fn
        {_priority, 0}, mask -> mask
        {priority, _color}, mask -> mask ||| 1 <<< priority
      end)

    {List.to_tuple(pixels), priorities, tile_cache}
  end

  defp interlaced_bg_coordinate(%{interlace?: true, bg_mode: mode} = ppu, bg, screen_y)
       when mode in [5, 6] do
    field = if mosaic_axis_enabled?(ppu, bg, :vertical), do: 0, else: ppu.interlace_field
    (screen_y <<< 1) + field
  end

  defp interlaced_bg_coordinate(_ppu, _bg, screen_y), do: screen_y

  # Horizontal blocks are screen-aligned. Vertical blocks restart when MOSAIC
  # changes, at the scanline-granular boundary retained by this renderer.
  defp mosaic_coordinate(ppu, bg, :vertical, coordinate) do
    size = (ppu.mosaic >>> 4) + 1

    if size > 1 and mosaic_axis_enabled?(ppu, bg, :vertical),
      do: coordinate - Integer.mod(coordinate - ppu.mosaic_start_line, size),
      else: coordinate
  end

  defp apply_horizontal_mosaic(pixels, ppu, bg) do
    hires_scale = if ppu.bg_mode in [5, 6], do: 2, else: 1
    size = ((ppu.mosaic >>> 4) + 1) * hires_scale
    width = length(pixels)

    if size > 1 and mosaic_axis_enabled?(ppu, bg, :horizontal) do
      source = List.to_tuple(pixels)
      for x <- 0..(width - 1), do: elem(source, x - rem(x, size))
    else
      pixels
    end
  end

  defp mosaic_axis_enabled?(%{bg_mode: 7, extbg?: true, mosaic: mosaic}, _bg, :vertical),
    do: (mosaic &&& 0x01) != 0

  defp mosaic_axis_enabled?(%{bg_mode: 7, extbg?: true, mosaic: mosaic}, _bg, :horizontal),
    do: (mosaic &&& 0x02) != 0

  defp mosaic_axis_enabled?(%{mosaic: mosaic}, bg, _axis),
    do: (mosaic &&& 1 <<< bg) != 0

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

  defp render_offset_bg_row(
         ppu,
         bg,
         bpp,
         screen_y,
         output_width,
         tile_width,
         tile_height,
         tile_cache
       ) do
    hires_shift = if ppu.bg_mode == 6, do: 1, else: 0
    hscroll = elem(ppu.bg_hofs, bg) <<< hires_shift
    vscroll = elem(ppu.bg_vofs, bg)

    0..(output_width - 1)
    |> Enum.map_reduce(tile_cache, fn output_x, tile_cache ->
      {source_x, source_y} =
        offset_bg_coordinates(
          ppu,
          bg,
          output_x,
          screen_y,
          hscroll,
          vscroll,
          tile_width,
          hires_shift
        )

      bg_pixel(ppu, bg, bpp, source_x, source_y, tile_width, tile_height, tile_cache)
    end)
  end

  defp offset_bg_coordinates(
         ppu,
         bg,
         output_x,
         screen_y,
         hscroll,
         vscroll,
         tile_width,
         hires_shift
       ) do
    default = {output_x + hscroll, screen_y + vscroll}
    offset_x = output_x + (hscroll &&& 7)

    if offset_x < tile_width do
      default
    else
      lookup_x =
        offset_x - tile_width + ((elem(ppu.bg_hofs, 2) &&& bnot(7)) <<< hires_shift)

      hlookup = offset_tilemap_entry(ppu, lookup_x, elem(ppu.bg_vofs, 2), hires_shift)
      valid_bit = 0x2000 <<< bg

      case ppu.bg_mode do
        4 ->
          cond do
            (hlookup &&& valid_bit) == 0 -> default
            (hlookup &&& 0x8000) == 0 -> {offset_x + (hlookup &&& bnot(7)), elem(default, 1)}
            true -> {elem(default, 0), screen_y + hlookup}
          end

        _mode ->
          vlookup =
            offset_tilemap_entry(ppu, lookup_x, elem(ppu.bg_vofs, 2) + 8, hires_shift)

          source_x =
            if (hlookup &&& valid_bit) != 0,
              do: offset_x + (hlookup &&& bnot(7)),
              else: elem(default, 0)

          source_y =
            if (vlookup &&& valid_bit) != 0,
              do: screen_y + vlookup,
              else: elem(default, 1)

          {source_x, source_y}
      end
    end
  end

  defp offset_tilemap_entry(ppu, x, y, hires_shift) do
    large_tiles? = (ppu.bg_tile_size &&& 1 <<< 2) != 0
    tile_height = if large_tiles?, do: 16, else: 8
    tile_width = if hires_shift == 1, do: 16, else: tile_height
    tilemap_entry(ppu, 2, div(x, tile_width), div(y, tile_height))
  end

  defp bg_pixel(ppu, bg, bpp, x, y, tile_width, tile_height, tile_cache) do
    tile_x = div(x, tile_width)
    tile_y = div(y, tile_height)
    entry = tilemap_entry(ppu, bg, tile_x, tile_y)
    hflip? = (entry &&& 0x4000) != 0
    vflip? = (entry &&& 0x8000) != 0
    pixel_x = rem(x, tile_width)
    pixel_y = rem(y, tile_height)
    pixel_x = if hflip?, do: tile_width - 1 - pixel_x, else: pixel_x
    pixel_y = if vflip?, do: tile_height - 1 - pixel_y, else: pixel_y
    tile = (entry &&& 0x03FF) + div(pixel_y, 8) * 16 + div(pixel_x, 8)
    {row, tile_cache} = cached_tile_row(ppu, bg, bpp, tile, rem(pixel_y, 8), tile_cache)
    tile_color = elem(row, rem(pixel_x, 8))

    {{entry >>> 13 &&& 1, bg_color_index(ppu, bg, bpp, entry, tile_color)}, tile_cache}
  end

  defp bg_tile_pixels(
         ppu,
         bg,
         bpp,
         tile_x,
         tile_y,
         y,
         tile_width,
         tile_height,
         tile_cache
       ) do
    entry = tilemap_entry(ppu, bg, tile_x, tile_y)
    tile = entry &&& 0x03FF
    hflip? = (entry &&& 0x4000) != 0
    vflip? = (entry &&& 0x8000) != 0
    py = rem(y, tile_height)
    py = if vflip?, do: tile_height - 1 - py, else: py
    tile = tile + div(py, 8) * 16
    {left, tile_cache} = cached_tile_row(ppu, bg, bpp, tile, rem(py, 8), tile_cache)

    {right, tile_cache} =
      if tile_width == 16,
        do: cached_tile_row(ppu, bg, bpp, tile + 1, rem(py, 8), tile_cache),
        else: {nil, tile_cache}

    priority = entry >>> 13 &&& 1

    pixels =
      for output_x <- 0..(tile_width - 1) do
        source_x = if hflip?, do: tile_width - 1 - output_x, else: output_x
        row = if source_x < 8, do: left, else: right
        tile_color = elem(row, source_x &&& 7)
        {priority, bg_color_index(ppu, bg, bpp, entry, tile_color)}
      end

    {pixels, tile_cache}
  end

  defp bg_color_index(_ppu, _bg, _bpp, _entry, 0), do: 0

  defp bg_color_index(_ppu, _bg, 8, entry, tile_color),
    do: tile_color ||| (entry >>> 10 &&& 0x07) <<< 8

  defp bg_color_index(ppu, bg, bpp, entry, tile_color) do
    palette_base = if ppu.bg_mode == 0, do: bg * 32, else: 0
    palette_base + (entry >>> 10 &&& 0x07) * (1 <<< bpp) + tile_color
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

  defp decode_tile_row(ppu, bg, 8, tile, y) do
    base = elem(ppu.bg_name_base, bg) * 0x2000 + tile * 64

    planes =
      for pair <- 0..3 do
        address = base + y * 2 + pair * 16
        {vram_byte(ppu.vram, address), vram_byte(ppu.vram, address + 1)}
      end

    List.to_tuple(
      for x <- 0..7 do
        bit = 7 - x

        Enum.reduce(Enum.with_index(planes), 0, fn {{low, high}, pair}, color ->
          color ||| (low >>> bit &&& 1) <<< (pair * 2) |||
            (high >>> bit &&& 1) <<< (pair * 2 + 1)
        end)
      end
    )
  end

  defp palette(ppu) do
    List.to_tuple(for index <- 0..255, do: :array.get(index, ppu.cgram))
  end

  defp expand5(value, brightness) do
    # The DAC applies master brightness while the channel is still 5-bit, then
    # converts that result to 8-bit by repeating its high bits.  Scaling an
    # already-expanded 8-bit channel gives different rounding for mid-range
    # colors (for example, 16 must become 132 at full brightness, not 131).
    scaled = div(value * brightness, 15)
    scaled <<< 3 ||| scaled >>> 2
  end

  defp m7_product(a, b) do
    signed_a = if a >= 0x8000, do: a - 0x10000, else: a
    multiplier = b >>> 8
    signed_b = if multiplier >= 0x80, do: multiplier - 0x100, else: multiplier
    signed_a * signed_b &&& 0xFFFFFF
  end

  # Hardware redirects active-display OAM/CGRAM access to addresses driven by
  # the live fetcher. The deferred renderer has no live fetch address, so the
  # inaccessible path preserves register phase/address effects without falsely
  # mutating the programmer-selected address.
  defp write_oam(ppu, value, memory_accessible?) do
    address = ppu.oam_internal_address

    {oam, dirty?} =
      cond do
        address < 0x200 and (address &&& 1) == 0 ->
          {ppu.oam, false}

        not memory_accessible? ->
          {ppu.oam, false}

        address < 0x200 ->
          low_address = address - 1

          dirty? =
            :array.get(low_address, ppu.oam) != ppu.oam_latch or
              :array.get(address, ppu.oam) != value

          oam =
            :array.set(address, value, :array.set(low_address, ppu.oam_latch, ppu.oam))

          {oam, dirty?}

        true ->
          physical = oam_physical_address(address)
          dirty? = :array.get(physical, ppu.oam) != value
          {:array.set(physical, value, ppu.oam), dirty?}
      end

    %{
      ppu
      | oam: oam,
        oam_latch: value,
        oam_version: ppu.oam_version + if(dirty?, do: 1, else: 0),
        render_dirty?: ppu.render_dirty? or dirty?
    }
    |> set_oam_internal_address(address + 1 &&& 0x3FF)
  end

  defp write_cgram(%{cgram_second_byte?: false} = ppu, value, _memory_accessible?),
    do: %{ppu | cgram_write_latch: value, cgram_second_byte?: true}

  defp write_cgram(ppu, value, memory_accessible?) do
    color = ppu.cgram_write_latch ||| (value &&& 0x7F) <<< 8
    dirty? = memory_accessible? and :array.get(ppu.cgadd, ppu.cgram) != color
    cgram = if memory_accessible?, do: :array.set(ppu.cgadd, color, ppu.cgram), else: ppu.cgram

    %{
      ppu
      | cgram: cgram,
        cgadd: ppu.cgadd + 1 &&& 0xFF,
        cgram_second_byte?: false,
        render_dirty?: ppu.render_dirty? or dirty?,
        cgram_version: ppu.cgram_version + if(dirty?, do: 1, else: 0)
    }
  end

  defp write_vram(ppu, byte, _value, false), do: increment_vmadd_after_access(ppu, byte)

  defp write_vram(ppu, byte, value, true) do
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

    if increment_vmadd_after_byte?(ppu, byte) do
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

  defp increment_vmadd_after_access(ppu, byte) do
    if increment_vmadd_after_byte?(ppu, byte),
      do: %{ppu | vmadd: ppu.vmadd + vram_increment(ppu.vmain) &&& 0xFFFF},
      else: ppu
  end

  defp increment_vmadd_after_byte?(ppu, byte),
    do: (ppu.vmain &&& 0x80) != 0 == (byte == :high)

  defp render_or_reuse_frame(ppu), do: render_or_reuse_frame(ppu, render_key(ppu))

  defp start_render_task(ppu) do
    key = render_key(ppu)

    case ppu do
      %{
        cached_render_key: ^key,
        cached_frame_data: data,
        cached_frame_width: width
      }
      when is_binary(data) ->
        frame = %{
          number: ppu.frame_number,
          width: width,
          height: ppu.cached_frame_height,
          pixel_format: :rgb24,
          data: data
        }

        %{ppu | render_dirty?: false, render_task: {:ready, frame}}

      _ ->
        snapshot = %{ppu | frame_ready: nil, render_task: nil}

        task =
          Beamicom.SNES.DSPTask.start_reusable(:ppu_renderer, fn -> render_frame(snapshot) end)

        %{ppu | render_dirty?: false, render_task: {:running, task, key}}
    end
  end

  defp finish_render_task(%{render_task: nil} = ppu), do: ppu

  defp finish_render_task(%{render_task: {:ready, frame}} = ppu) do
    %{ppu | frame_ready: frame, render_task: nil, reused_frames: ppu.reused_frames + 1}
  end

  defp finish_render_task(%{render_task: {:running, task, key}} = ppu) do
    frame = Beamicom.SNES.DSPTask.await(task)

    %{
      ppu
      | frame_ready: frame,
        render_task: nil,
        cached_render_key: key,
        cached_frame_data: frame.data,
        cached_frame_width: frame.width,
        cached_frame_height: frame.height,
        rendered_frames: ppu.rendered_frames + 1
    }
  end

  defp render_or_reuse_frame(
         %{cached_render_key: key, cached_frame_data: data, cached_frame_width: width} = ppu,
         key
       )
       when is_binary(data) do
    frame = %{
      number: ppu.frame_number,
      width: width,
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
         cached_frame_width: frame.width,
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
      ppu.mosaic,
      ppu.obsel,
      ppu.obj_priority_rotation?,
      ppu.obj_first,
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
      ppu.interlace?,
      ppu.obj_interlace?,
      ppu.overscan?,
      ppu.pseudo_hires?,
      ppu.extbg?,
      ppu.interlace_field,
      ppu.scanline_states,
      ppu.raster_segments,
      render_vram_key(ppu),
      if((ppu.main_screen &&& 0x10) != 0 or (ppu.sub_screen &&& 0x10) != 0,
        do: ppu.oam_version,
        else: 0
      ),
      ppu.cgram_version,
      ppu.video_filter,
      ppu.video_filter_options,
      video_filter_frame_key(ppu)
    }
  end

  defp video_filter_frame_key(%{video_filter: :native}), do: 0

  defp video_filter_frame_key(ppu) do
    if Keyword.get(ppu.video_filter_options, :merge_fields, true),
      do: 0,
      else: rem(ppu.frame_number, 2)
  end

  defp render_vram_key(%{bg_mode: 7} = ppu) do
    backgrounds = if ppu.extbg?, do: 0x03, else: 0x01

    if (ppu.main_screen &&& backgrounds) != 0 or (ppu.sub_screen &&& backgrounds) != 0,
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
        tile_bytes = if bpp == 2, do: 0x4000, else: bpp * 0x2000
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

  defp reset_oam_address(ppu, oamadd, priority_rotation?) do
    internal_address = oamadd <<< 1
    obj_first = first_sprite(internal_address, priority_rotation?)

    dirty? =
      ppu.obj_priority_rotation? != priority_rotation? or
        ppu.obj_first != obj_first

    %{
      ppu
      | oamadd: oamadd,
        oam_internal_address: internal_address,
        obj_priority_rotation?: priority_rotation?,
        obj_first: obj_first,
        render_dirty?: ppu.render_dirty? or dirty?
    }
  end

  defp set_oam_internal_address(ppu, address) do
    obj_first = first_sprite(address, ppu.obj_priority_rotation?)

    %{
      ppu
      | oam_internal_address: address,
        obj_first: obj_first,
        render_dirty?: ppu.render_dirty? or ppu.obj_first != obj_first
    }
  end

  defp first_sprite(address, true), do: address >>> 2 &&& 0x7F
  defp first_sprite(_address, false), do: 0

  defp oam_physical_address(address) when address < 0x200, do: address
  defp oam_physical_address(address), do: 0x200 + (address &&& 0x1F)

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
      ppu.m7y,
      ppu.extbg?,
      ppu.mosaic,
      ppu.obj_priority_rotation?,
      ppu.obj_first,
      ppu.mosaic_start_line,
      ppu.obj_interlace?,
      ppu.pseudo_hires?,
      ppu.interlace?,
      ppu.interlace_field
    }
  end

  defp apply_visual_state(
         ppu,
         {force_blank?, brightness, bg_mode, bg3_priority?, bg_tile_size, bg_sc, bg_name_base,
          bg_hofs, bg_vofs, obsel, window_select, window_positions, window_logic, main_screen,
          sub_screen, main_window, sub_window, color_window_select, color_math, fixed_color,
          cgram_version, cgram, m7sel, m7hofs, m7vofs, m7a, m7b, m7c, m7d, m7x, m7y, extbg?,
          mosaic, obj_priority_rotation?, obj_first, mosaic_start_line, obj_interlace?,
          pseudo_hires?, interlace?, interlace_field}
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
        m7y: m7y,
        extbg?: extbg?,
        mosaic: mosaic,
        obj_priority_rotation?: obj_priority_rotation?,
        obj_first: obj_first,
        mosaic_start_line: mosaic_start_line,
        obj_interlace?: obj_interlace?,
        pseudo_hires?: pseudo_hires?,
        interlace?: interlace?,
        interlace_field: interlace_field
    }
  end

  defp reload_mosaic_for_scanline(%{mosaic_reload_pending?: true} = ppu, screen_line) do
    %{ppu | mosaic_start_line: screen_line, mosaic_reload_pending?: false}
  end

  defp reload_mosaic_for_scanline(ppu, _screen_line), do: ppu

  defp mosaic_active?(%{mosaic: mosaic, scanline_states: states}) do
    active? = fn value -> (value &&& 0x0F) != 0 and value >>> 4 != 0 end

    active?.(mosaic) or
      (is_list(states) and Enum.any?(states, fn state -> active?.(elem(state, 32)) end))
  end

  defp scanline_states(%{scanline_states: states}, height) when is_list(states) do
    if length(states) == height, do: states |> Enum.reverse() |> List.to_tuple(), else: nil
  end

  defp scanline_states(_ppu, _height), do: nil

  defp obj_state(ppu),
    do: {
      ppu.obsel,
      ppu.obj_priority_rotation?,
      ppu.obj_first,
      ppu.obj_interlace?,
      ppu.interlace_field
    }

  defp visual_obj_state(state),
    do: {elem(state, 9), elem(state, 33), elem(state, 34), elem(state, 36), elem(state, 39)}

  defp read_vram(ppu, byte, memory_accessible?) do
    value =
      if byte == :low,
        do: ppu.vram_read_buffer &&& 0xFF,
        else: ppu.vram_read_buffer >>> 8

    ppu =
      if increment_vmadd_after_byte?(ppu, byte) do
        read_buffer =
          if memory_accessible?, do: vram_word(ppu, translated_vmadd(ppu)), else: 0

        %{
          ppu
          | vram_read_buffer: read_buffer,
            vmadd: ppu.vmadd + vram_increment(ppu.vmain) &&& 0xFFFF
        }
      else
        ppu
      end

    {value, ppu}
  end

  defp load_vram_read_buffer(ppu, memory_accessible?) do
    value = if memory_accessible?, do: vram_word(ppu, translated_vmadd(ppu)), else: 0
    %{ppu | vram_read_buffer: value}
  end

  defp read_cgram(%{cgram_second_byte?: false} = ppu, open_bus, false),
    do: {open_bus, %{ppu | cgram_second_byte?: true}}

  defp read_cgram(%{cgram_second_byte?: false} = ppu, _open_bus, true) do
    color = :array.get(ppu.cgadd, ppu.cgram)
    {color &&& 0xFF, %{ppu | cgram_second_byte?: true}}
  end

  defp read_cgram(ppu, open_bus, false),
    do: {open_bus, %{ppu | cgadd: ppu.cgadd + 1 &&& 0xFF, cgram_second_byte?: false}}

  defp read_cgram(ppu, _open_bus, true) do
    color = :array.get(ppu.cgadd, ppu.cgram)
    value = (ppu.ppu2_mdr &&& 0x80) ||| (color >>> 8 &&& 0x7F)
    {value, %{ppu | cgadd: ppu.cgadd + 1 &&& 0xFF, cgram_second_byte?: false}}
  end

  defp latch_ppu1_mdr({value, ppu}), do: {value, %{ppu | ppu1_mdr: value}}
  defp latch_ppu2_mdr({value, ppu}), do: {value, %{ppu | ppu2_mdr: value}}

  defp read_stat77(ppu) do
    value =
      (ppu.ppu1_mdr &&& 0x10) ||| 0x01 |||
        if(ppu.obj_range_over?, do: 0x40, else: 0) |||
        if(ppu.obj_time_over?, do: 0x80, else: 0)

    {value, %{ppu | ppu1_mdr: value}}
  end

  defp read_stat78(ppu, region, field, counter_latch_enabled?) do
    latch_bit =
      if counter_latch_enabled?,
        do: if(ppu.counter_latched?, do: 0x40, else: 0),
        else: 0x40

    value =
      (ppu.ppu2_mdr &&& 0x20) ||| 0x03 |||
        if(region == :pal, do: 0x10, else: 0) ||| latch_bit |||
        if(field == 1, do: 0x80, else: 0)

    ppu = %{
      ppu
      | ppu2_mdr: value,
        hcounter_second_byte?: false,
        vcounter_second_byte?: false,
        counter_latched?: if(counter_latch_enabled?, do: false, else: ppu.counter_latched?)
    }

    {value, ppu}
  end

  defp ppu_memory_accessible?(_ppu, :unrestricted), do: true

  defp ppu_memory_accessible?(ppu, %{vline: vline}) do
    ppu.force_blank? or vline >= vblank_start(ppu)
  end

  defp cgram_accessible?(_ppu, :unrestricted), do: true

  defp cgram_accessible?(ppu, %{vline: vline, hclock: hclock}) do
    ppu_memory_accessible?(ppu, %{vline: vline}) or vline == 0 or hclock < 88 or hclock >= 1096
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
