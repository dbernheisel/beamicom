defmodule Beamicom.SNES.SaveState do
  @moduledoc """
  Versioned, ROM-stripped serialization for SNES machines.

  Completed video/audio are transient host output and are removed. In-flight
  DSP work is observed without consuming the runtime's task, while process and
  resource references are converted into portable values before encoding.
  """

  alias Beamicom.SNES.{
    APU,
    BoundedZlib,
    Bus,
    CPU,
    Cartridge,
    Cx4,
    DSP,
    DSP1,
    Machine,
    PPU,
    SA1,
    SPC700,
    SuperFX,
    Timing
  }

  @magic "BEAMICOM_SNES_STATE"
  @version 4
  @max_compressed_state_bytes 1024 * 1024
  @max_state_bytes 8 * 1024 * 1024
  @max_rom_bytes 16 * 1024 * 1024
  @max_compressed_rom_bytes @max_rom_bytes + 1024 * 1024
  @dma_keys [
    :dmap,
    :bbad,
    :a_addr,
    :a_bank,
    :size,
    :indirect_bank,
    :table_addr,
    :line_counter,
    :indirect_addr,
    :hdma_active?,
    :hdma_do_transfer?
  ]
  @type identity :: %{size: non_neg_integer(), sha256: binary()}

  @doc "Splits a machine into compressed state and immutable-ROM blobs."
  def split(%Machine{cartridge: %Cartridge{rom: rom}} = machine) when is_binary(rom) do
    identity = rom_identity(rom)
    cartridge = %{machine.cartridge | rom: <<>>}

    ppu = %{
      machine.bus.ppu
      | cache_identity: nil,
        frame_ready: nil,
        cached_render_key: nil,
        cached_frame_data: nil,
        cached_frame_width: nil,
        cached_frame_height: nil,
        obj_limit_cache_key: nil,
        obj_limit_rows: nil,
        render_dirty?: true,
        render_task: nil
    }

    bus = %{
      machine.bus
      | cartridge: cartridge,
        runtime: Bus.serialized_runtime(machine.bus),
        ppu: ppu,
        apu: APU.serialized_snapshot(machine.bus.apu),
        coprocessor: snapshot_coprocessor(machine.bus.coprocessor)
    }

    stripped = %{machine | cartridge: cartridge, bus: bus}
    payload = %{magic: @magic, version: @version, rom: identity, machine: stripped}
    state = payload |> :erlang.term_to_binary([:deterministic]) |> :zlib.compress()

    if byte_size(state) > Beamicom.SNES.VisualCode.max_payload_bytes(),
      do: raise(ArgumentError, "compressed SNES state exceeds share-image capacity")

    {state, :zlib.compress(rom)}
  end

  @doc "Restores a machine and rejects corrupt, unsupported, or mismatched ROM data."
  def merge(state_blob, rom_blob) when is_binary(state_blob) and is_binary(rom_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload),
         {:ok, rom} <- decode_rom(rom_blob),
         :ok <- validate_rom(rom, payload.rom),
         {:ok, cartridge} <- Cartridge.load(rom),
         {:ok, machine} <- restore_machine(payload.machine, cartridge) do
      {:ok, machine}
    else
      {:error, :snes_header_not_found} -> {:error, :corrupt_rom}
      {:error, _reason} = error -> error
    end
  end

  @doc "Reads the validated state envelope without requiring the cartridge ROM."
  def metadata(state_blob) when is_binary(state_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload) do
      {:ok, %{version: payload.version, rom: payload.rom}}
    end
  end

  @doc "Returns the stable ROM identity used by save states."
  def rom_identity(rom) when is_binary(rom),
    do: %{size: byte_size(rom), sha256: :crypto.hash(:sha256, rom)}

  defp decode_state(blob) when byte_size(blob) <= @max_compressed_state_bytes do
    with {:ok, inflated} <- BoundedZlib.inflate(blob, @max_state_bytes) do
      try do
        {:ok, :erlang.binary_to_term(inflated, [:safe])}
      rescue
        _error -> {:error, :corrupt}
      end
    else
      {:error, :too_large} -> {:error, :state_too_large}
      {:error, :invalid} -> {:error, :corrupt}
    end
  end

  defp decode_state(_blob), do: {:error, :state_too_large}

  defp decode_rom(blob) when byte_size(blob) <= @max_compressed_rom_bytes do
    case BoundedZlib.inflate(blob, @max_rom_bytes) do
      {:ok, rom} -> {:ok, rom}
      {:error, :too_large} -> {:error, :rom_too_large}
      {:error, :invalid} -> {:error, :corrupt_rom}
    end
  end

  defp decode_rom(_blob), do: {:error, :rom_too_large}

  defp validate_envelope(
         %{
           magic: @magic,
           version: @version,
           rom: %{size: size, sha256: digest},
           machine: %Machine{cartridge: %Cartridge{rom: <<>>}, bus: %Bus{}} = machine
         } = payload
       ) do
    valid =
      exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and
        exact_map_keys?(payload.rom, [:size, :sha256]) and
        exact_struct?(machine, Machine) and exact_struct?(machine.cartridge, Cartridge) and
        exact_struct?(machine.bus, Bus) and exact_struct?(machine.bus.cartridge, Cartridge) and
        exact_struct?(machine.cpu, CPU) and exact_struct?(machine.bus.ppu, PPU) and
        exact_struct?(machine.bus.apu, APU) and
        match?(%Cartridge{rom: <<>>}, machine.bus.cartridge) and
        machine.cartridge == machine.bus.cartridge and is_integer(size) and size > 0 and
        size <= @max_rom_bytes and is_binary(digest) and byte_size(digest) == 32

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_envelope(%{magic: @magic, version: version}) when is_integer(version),
    do: {:error, {:unsupported_version, version}}

  defp validate_envelope(_payload), do: {:error, :corrupt}

  defp validate_rom(rom, expected) do
    if rom_identity(rom) == expected, do: :ok, else: {:error, :rom_mismatch}
  end

  defp restore_machine(%Machine{} = machine, cartridge) do
    with {:ok, coprocessor} <- restore_coprocessor(machine.bus.coprocessor, cartridge),
         {:ok, apu} <- APU.restore_serialized_snapshot(machine.bus.apu) do
      ppu = %{
        machine.bus.ppu
        | cache_identity: make_ref(),
          frame_ready: nil,
          cached_render_key: nil,
          cached_frame_data: nil,
          cached_frame_width: nil,
          cached_frame_height: nil,
          render_dirty?: true,
          render_task: nil
      }

      bus = %{
        Bus.restore_runtime(machine.bus)
        | cartridge: cartridge,
          ppu: ppu,
          apu: apu,
          coprocessor: coprocessor
      }

      restored = %{machine | cartridge: cartridge, bus: bus}

      if valid_machine?(restored), do: {:ok, restored}, else: {:error, :corrupt}
    end
  end

  defp valid_machine?(%Machine{cpu: %CPU{}, bus: %Bus{} = bus, cartridge: %Cartridge{}} = machine) do
    exact_struct?(machine, Machine) and exact_struct?(machine.cpu, CPU) and
      machine.cartridge == bus.cartridge and validate_cpu(machine.cpu) and
      validate_bus(bus, machine.cartridge)
  end

  defp valid_machine?(_machine), do: false

  defp valid_coprocessor?(nil), do: true
  defp valid_coprocessor?(%SuperFX{} = coprocessor), do: exact_struct?(coprocessor, SuperFX)
  defp valid_coprocessor?(%SA1{} = coprocessor), do: exact_struct?(coprocessor, SA1)

  defp valid_coprocessor?(%Cx4{} = coprocessor),
    do: exact_struct?(coprocessor, Cx4) and array_size?(coprocessor.ram, 0x2000)

  defp valid_coprocessor?(%DSP1{} = coprocessor), do: exact_struct?(coprocessor, DSP1)

  defp valid_coprocessor?(_coprocessor), do: false

  defp snapshot_coprocessor(%SuperFX{} = super_fx) do
    %{
      super_fx
      | ram: atomics_to_binary(super_fx.ram),
        bram: nil,
        cache: atomics_to_binary(super_fx.cache)
    }
  end

  defp snapshot_coprocessor(%SA1{} = sa1) do
    bwram = if sa1.bwram, do: atomics_to_binary(sa1.bwram), else: nil
    %{sa1 | iram: atomics_to_binary(sa1.iram), bwram: bwram}
  end

  defp snapshot_coprocessor(coprocessor), do: coprocessor

  defp restore_coprocessor(%SuperFX{} = super_fx, cartridge) do
    expected = SuperFX.cartridge?(cartridge)

    if exact_struct?(super_fx, SuperFX) and expected and is_binary(super_fx.ram) and
         byte_size(super_fx.ram) == super_fx.ram_size and
         is_nil(super_fx.bram) and is_binary(super_fx.cache) and byte_size(super_fx.cache) == 512 do
      ram = atomics_from_binary(super_fx.ram)
      {:ok, %{super_fx | ram: ram, bram: ram, cache: atomics_from_binary(super_fx.cache)}}
    else
      {:error, :corrupt}
    end
  end

  defp restore_coprocessor(%SA1{} = sa1, cartridge) do
    expected = SA1.cartridge?(cartridge)

    valid_bwram? =
      (sa1.bwram_size == 0 and is_nil(sa1.bwram)) or
        (sa1.bwram_size > 0 and is_binary(sa1.bwram) and
           byte_size(sa1.bwram) == sa1.bwram_size)

    if exact_struct?(sa1, SA1) and expected and is_binary(sa1.iram) and
         byte_size(sa1.iram) == 0x800 and valid_bwram? do
      bwram = if sa1.bwram, do: atomics_from_binary(sa1.bwram), else: nil
      {:ok, %{sa1 | iram: atomics_from_binary(sa1.iram), bwram: bwram}}
    else
      {:error, :corrupt}
    end
  end

  defp restore_coprocessor(nil, cartridge) do
    if coprocessor_cartridge?(cartridge), do: {:error, :corrupt}, else: {:ok, nil}
  end

  defp restore_coprocessor(%Cx4{} = cx4, cartridge) do
    if exact_struct?(cx4, Cx4) and Cx4.cartridge?(cartridge),
      do: {:ok, cx4},
      else: {:error, :corrupt}
  end

  defp restore_coprocessor(%DSP1{} = dsp1, cartridge) do
    if exact_struct?(dsp1, DSP1) and DSP1.cartridge?(cartridge),
      do: {:ok, dsp1},
      else: {:error, :corrupt}
  end

  defp restore_coprocessor(_coprocessor, _cartridge), do: {:error, :corrupt}

  defp coprocessor_cartridge?(cartridge) do
    Cx4.cartridge?(cartridge) or SuperFX.cartridge?(cartridge) or
      DSP1.cartridge?(cartridge) or SA1.cartridge?(cartridge)
  end

  defp validate_cpu(cpu) do
    Enum.all?([cpu.a, cpu.x, cpu.y, cpu.d, cpu.s, cpu.pc], &word?/1) and
      Enum.all?([cpu.db, cpu.pb, cpu.p], &byte?/1) and is_boolean(cpu.emulation?) and
      is_boolean(cpu.waiting?) and is_boolean(cpu.stopped?) and
      valid_poll_loop?(cpu.poll_loop) and non_negative_integer?(cpu.master_clocks) and
      non_negative_integer?(cpu.instructions)
  end

  defp validate_bus(bus, cartridge) do
    exact_struct?(bus, Bus) and exact_struct?(bus.cartridge, Cartridge) and
      array_size?(bus.wram, 128 * 1024) and
      array_size?(bus.sram, cartridge.header.declared_ram_size || 0) and
      validate_timing(bus.timing) and validate_ppu(bus.ppu) and validate_apu(bus.apu) and
      Enum.all?(
        [bus.fast_rom?, bus.nmi_enable?, bus.nmi_flag?, bus.nmi_pending?, bus.irq_flag?],
        &is_boolean/1
      ) and
      Bus.valid_runtime?(bus) and byte?(Bus.open_bus(bus)) and byte?(bus.wrio) and
      bus.irq_mode in [:off, :h, :v, :hv] and
      Enum.all?([bus.htime, bus.vtime], &integer_between?(&1, 0, 0x1FF)) and
      byte?(bus.multiplicand) and word?(bus.dividend) and word?(bus.quotient) and
      word?(bus.product_remainder) and integer_between?(bus.wmadd, 0, 0x1FFFF) and
      valid_joypad?(bus.joypad) and valid_dma_channels?(bus.dma_channels) and
      byte?(bus.hdma_enable) and non_negative_integer?(bus.apu_pending_clocks) and
      non_negative_integer?(Bus.cpu_pending_clocks(bus)) and valid_coprocessor?(bus.coprocessor)
  end

  defp validate_timing(%Timing{} = timing) do
    exact_struct?(timing, Timing) and timing.region in [:ntsc, :pal] and
      non_negative_integer?(timing.hclock) and non_negative_integer?(timing.vline) and
      timing.field in [0, 1] and non_negative_integer?(timing.frame) and
      is_boolean(timing.interlace?) and is_boolean(timing.overscan?) and
      non_negative_integer?(timing.master_clocks)
  end

  defp validate_timing(_timing), do: false

  defp validate_ppu(%PPU{} = ppu) do
    integer_fields = [
      ppu.brightness,
      ppu.bg_mode,
      ppu.bg_tile_size,
      ppu.mosaic,
      ppu.mosaic_start_line,
      ppu.scroll_latch,
      ppu.bg_hofs_latch,
      ppu.m7_latch,
      ppu.m7sel,
      ppu.m7hofs,
      ppu.m7vofs,
      ppu.m7a,
      ppu.m7b,
      ppu.m7c,
      ppu.m7d,
      ppu.m7x,
      ppu.m7y,
      ppu.m7_product,
      ppu.obsel,
      ppu.oamadd,
      ppu.oam_internal_address,
      ppu.oam_latch,
      ppu.obj_first,
      ppu.oam_version,
      ppu.vmain,
      ppu.vmadd,
      ppu.vram_read_buffer,
      ppu.cgadd,
      ppu.cgram_write_latch,
      ppu.main_screen,
      ppu.sub_screen,
      ppu.main_window,
      ppu.sub_window,
      ppu.color_window_select,
      ppu.color_math,
      ppu.fixed_color,
      ppu.interlace_field,
      ppu.latched_hcounter,
      ppu.latched_vcounter,
      ppu.ppu1_mdr,
      ppu.ppu2_mdr,
      ppu.frame_number,
      ppu.vram_version,
      ppu.cgram_version,
      ppu.rendered_frames,
      ppu.reused_frames
    ]

    boolean_fields = [
      ppu.force_blank?,
      ppu.bg3_priority?,
      ppu.mosaic_reload_pending?,
      ppu.cgram_second_byte?,
      ppu.obj_priority_rotation?,
      ppu.interlace?,
      ppu.obj_interlace?,
      ppu.overscan?,
      ppu.pseudo_hires?,
      ppu.extbg?,
      ppu.hcounter_second_byte?,
      ppu.vcounter_second_byte?,
      ppu.counter_latched?,
      ppu.obj_range_over?,
      ppu.obj_time_over?,
      ppu.render_dirty?,
      ppu.render_pipeline?
    ]

    exact_struct?(ppu, PPU) and is_reference(ppu.cache_identity) and
      array_size?(ppu.vram, 0x10000) and array_size?(ppu.cgram, 256) and
      array_size?(ppu.oam, 544) and Enum.all?(integer_fields, &is_integer/1) and
      Enum.all?(boolean_fields, &is_boolean/1) and tuple_of_integers?(ppu.bg_sc, 4) and
      tuple_of_integers?(ppu.bg_name_base, 4) and tuple_of_integers?(ppu.bg_hofs, 4) and
      tuple_of_integers?(ppu.bg_vofs, 4) and tuple_of_integers?(ppu.window_select, 3) and
      tuple_of_integers?(ppu.window_positions, 4) and tuple_of_integers?(ppu.window_logic, 2) and
      tuple_of_integers?(ppu.vram_page_versions, 256) and
      tuple_of_integers?(ppu.vram_block_versions, 8) and byte?(ppu.cgram_write_latch) and
      byte?(ppu.ppu1_mdr) and byte?(ppu.ppu2_mdr) and
      valid_scanline_states?(ppu.scanline_states) and
      valid_raster_segments?(ppu.raster_segments) and is_nil(ppu.frame_ready) and
      is_nil(ppu.cached_render_key) and is_nil(ppu.cached_frame_data) and
      is_nil(ppu.cached_frame_height) and is_nil(ppu.obj_limit_cache_key) and
      is_nil(ppu.obj_limit_rows) and is_nil(ppu.render_task)
  end

  defp validate_ppu(_ppu), do: false

  defp validate_apu(%APU{} = apu) do
    exact_struct?(apu, APU) and tuple_of_bytes?(apu.cpu_to_apu, 4) and
      tuple_of_bytes?(apu.apu_to_cpu, 4) and
      apu.ipl_state in [:ready, :upload, :starting, :running, :restarting] and
      (is_nil(apu.ipl_counter) or byte?(apu.ipl_counter)) and word?(apu.ipl_address) and
      word?(apu.driver_entry) and non_negative_integer?(apu.driver_start_clocks) and
      (is_nil(apu.ipl_pending_port0) or byte?(apu.ipl_pending_port0)) and
      APU.RAM.valid?(apu.ram) and valid_spc?(apu.spc) and
      (is_nil(apu.spc) or apu.spc.ram == apu.ram) and
      Enum.all?(
        [apu.sample_phase, apu.spc_phase, apu.elapsed_master_clocks],
        &non_negative_integer?/1
      ) and
      apu.dsp_cycle_phase in 0..31 and valid_timeline_events?(apu.timeline_events) and
      apu.pending_frames == 0 and apu.pending_pcm == [] and apu.pending_spc_cycles == 0 and
      is_boolean(apu.async_dsp?) and valid_apu_renderer?(apu.apu_renderer) and
      is_nil(apu.dsp_task)
  end

  defp validate_apu(_apu), do: false

  defp valid_spc?(nil), do: true

  defp valid_spc?(%SPC700{} = spc) do
    exact_struct?(spc, SPC700) and APU.RAM.valid?(spc.ram) and
      Enum.all?([spc.a, spc.x, spc.y, spc.psw, spc.test, spc.control, spc.dsp_addr], &byte?/1) and
      word?(spc.pc) and byte?(spc.sp) and tuple_of_bytes?(spc.input_ports, 4) and
      tuple_of_bytes?(spc.output_ports, 4) and valid_dsp?(spc.dsp) and
      is_list(spc.dsp_events) and spc.access_events == [] and
      spc.capture_access_events? == false and tuple_of_integers?(spc.aux, 2) and
      tuple_of_integers?(spc.timer_targets, 3) and tuple_of_integers?(spc.timer_stages, 3) and
      tuple_of_integers?(spc.timer_outputs, 3) and tuple_of_integers?(spc.timer_phase, 3) and
      tuple_of_integers?(spc.timer_last_cycles, 3) and is_integer(spc.cycles) and
      is_integer(spc.bus_cycle) and is_nil(spc.bus_counter) and is_integer(spc.cycle_credit) and
      is_boolean(spc.sleeping?) and is_boolean(spc.stopped?) and
      not (spc.sleeping? and spc.stopped?)
  end

  defp valid_spc?(_spc), do: false

  defp valid_dsp?(%DSP{} = dsp) do
    exact_struct?(dsp, DSP) and tuple_of_bytes?(dsp.registers, 128) and
      valid_dsp_clock?(dsp.clock)
  end

  defp valid_dsp?(_dsp), do: false

  defp valid_dsp_clock?(%DSP.Clock{} = clock) do
    exact_struct?(clock, DSP.Clock) and integer_between?(clock.phase, 0, 31) and
      non_negative_integer?(clock.sample_counter) and tuple_of_bytes?(clock.registers, 128) and
      valid_dsp_mixer?(clock.mixer) and valid_dsp_pipeline?(clock.pipeline) and
      valid_voice_pipeline?(clock.voice_pipeline) and
      valid_dsp_noise?(clock.noise) and valid_echo_state?(clock.echo_state) and
      optional_signed_word?(clock.echo_left_read) and optional_signed_word?(clock.echo_right_read) and
      (is_nil(clock.echo_pending_state) or valid_echo_state?(clock.echo_pending_state)) and
      is_list(clock.echo_write_effects) and length(clock.echo_write_effects) <= 2 and
      Enum.all?(clock.echo_write_effects, &valid_echo_effect?/1) and
      optional_stereo_sample?(clock.echo_pcm) and byte?(clock.echo_flg_28) and
      byte?(clock.echo_flg_29)
  end

  defp valid_dsp_clock?(_clock), do: false

  defp valid_dsp_mixer?(nil), do: true

  defp valid_dsp_mixer?({voices, muted?, master_left, master_right, counter}) do
    is_tuple(voices) and tuple_size(voices) == 8 and
      voices |> Tuple.to_list() |> Enum.all?(&valid_dsp_mixer_voice?/1) and
      is_boolean(muted?) and signed_byte?(master_left) and signed_byte?(master_right) and
      integer_between?(counter, 0, 30_719)
  end

  defp valid_dsp_mixer?(_mixer), do: false

  defp valid_dsp_mixer_voice?({pitch, left, right, adsr1, adsr2, gain}) do
    integer_between?(pitch, 0, 0x3FFF) and signed_byte?(left) and signed_byte?(right) and
      byte?(adsr1) and byte?(adsr2) and byte?(gain)
  end

  defp valid_dsp_mixer_voice?(_voice), do: false

  defp valid_dsp_pipeline?(%DSP.Pipeline{} = pipeline) do
    exact_struct?(pipeline, DSP.Pipeline) and tuple_of_signed_words?(pipeline.voice_outputs, 8) and
      byte?(pipeline.completed_voices) and stereo_sample?(pipeline.main_bus) and
      stereo_sample?(pipeline.echo_bus) and stereo_sample?(pipeline.output)
  end

  defp valid_dsp_pipeline?(_pipeline), do: false

  defp valid_voice_pipeline?(%DSP.VoicePipeline{} = pipeline) do
    exact_struct?(pipeline, DSP.VoicePipeline) and
      is_tuple(pipeline.voices) and tuple_size(pipeline.voices) == 8 and
      pipeline.voices |> Tuple.to_list() |> Enum.all?(&valid_pipeline_voice?/1) and
      exact_struct?(pipeline.brr, DSP.BRR) and exact_struct?(pipeline.key, DSP.Key) and
      exact_struct?(pipeline.live, DSP.LiveRegisters) and byte?(pipeline.adsr0_latch) and
      integer_between?(pipeline.pitch_latch, 0, 0x7FFF) and
      signed_word?(pipeline.output_latch) and integer_between?(pipeline.counter, 0, 30_719) and
      is_boolean(pipeline.reset?) and is_boolean(pipeline.muted?) and byte?(pipeline.pmon) and
      byte?(pipeline.non) and byte?(pipeline.eon) and byte?(pipeline.latched_pmon) and
      byte?(pipeline.latched_non) and byte?(pipeline.latched_eon)
  end

  defp valid_voice_pipeline?(_pipeline), do: false

  defp valid_pipeline_voice?(%DSP.Voice{} = voice) do
    exact_struct?(voice, DSP.Voice) and integer_between?(voice.index, 0, 7) and
      is_boolean(voice.active?) and tuple_of_signed_bytes?(voice.volume, 2) and
      integer_between?(voice.pitch, 0, 0x3FFF) and byte?(voice.source) and byte?(voice.adsr0) and
      byte?(voice.adsr1) and byte?(voice.gain) and byte?(voice.envx) and
      signed_word?(voice.output) and tuple_of_signed_words?(voice.buffer, 12) and
      integer_between?(voice.buffer_offset, 0, 11) and
      integer_between?(voice.gaussian_offset, 0, 0x7FFF) and word?(voice.brr_address) and
      integer_between?(voice.brr_offset, 1, 8) and integer_between?(voice.keyon_delay, 0, 5) and
      integer_between?(voice.envelope_mode, 0, 3) and
      integer_between?(voice.envelope, 0, 0x07FF) and
      integer_between?(voice.hidden_envelope, -0x20, 0x0BFF) and is_boolean(voice.looped?)
  end

  defp valid_pipeline_voice?(_voice), do: false

  defp valid_dsp_noise?(%DSP.Noise{} = noise) do
    exact_struct?(noise, DSP.Noise) and integer_between?(noise.lfsr, 0, 0x7FFF) and
      integer_between?(noise.counter, 0, 30_719) and signed_word?(noise.sample)
  end

  defp valid_dsp_noise?(_noise), do: false

  defp valid_echo_state?(%DSP.Echo.State{} = state) do
    exact_struct?(state, DSP.Echo.State) and is_tuple(state.history) and
      tuple_size(state.history) == 8 and
      state.history |> Tuple.to_list() |> Enum.all?(&stereo_sample?/1) and
      state.history_offset in 0..7 and byte?(state.page) and word?(state.offset) and
      word?(state.length) and stereo_sample?(state.echo_input) and
      stereo_sample?(state.feedback_output)
  end

  defp valid_echo_state?(_state), do: false

  defp valid_echo_effect?(%DSP.Echo.Effect{} = effect) do
    exact_struct?(effect, DSP.Echo.Effect) and effect.operation in [:read, :write] and
      effect.phase in [22, 23, 29, 30] and effect.channel in [:left, :right] and
      word?(effect.address) and effect.size == 2 and
      (is_nil(effect.value) or signed_word?(effect.value)) and is_boolean(effect.enabled?)
  end

  defp valid_echo_effect?(_effect), do: false

  defp valid_apu_renderer?(:native), do: true
  defp valid_apu_renderer?(Beamicom.SNES.Nx.DSPRenderer), do: true
  defp valid_apu_renderer?(_renderer), do: false

  defp optional_signed_word?(nil), do: true
  defp optional_signed_word?(value), do: signed_word?(value)

  defp optional_stereo_sample?(nil), do: true
  defp optional_stereo_sample?(value), do: stereo_sample?(value)

  defp stereo_sample?({left, right}), do: signed_word?(left) and signed_word?(right)
  defp stereo_sample?(_sample), do: false

  defp signed_word?(value), do: integer_between?(value, -0x8000, 0x7FFF)

  defp valid_timeline_events?(events) when is_list(events) do
    length(events) <= APU.timeline_event_limit() and
      Enum.all?(events, &valid_timeline_event?/1) and chronological_events?(events)
  end

  defp valid_timeline_events?(_events), do: false

  defp valid_timeline_event?({clock, :ram_write, address, value}),
    do: non_negative_integer?(clock) and word?(address) and byte?(value)

  defp valid_timeline_event?({clock, :dsp_write, address, value}),
    do: non_negative_integer?(clock) and integer_between?(address, 0, 0x7F) and byte?(value)

  defp valid_timeline_event?(_event), do: false

  defp chronological_events?(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [{first, _, _, _}, {second, _, _, _}] -> first <= second end)
  end

  defp valid_poll_loop?(nil), do: true

  defp valid_poll_loop?({pb, pc, address, clocks}),
    do: byte?(pb) and word?(pc) and word?(address) and non_negative_integer?(clocks)

  defp valid_poll_loop?({:absolute_nonzero, pb, pc, address, clocks}),
    do:
      byte?(pb) and word?(pc) and integer_between?(address, 0, 0xFFFFFF) and
        non_negative_integer?(clocks)

  defp valid_poll_loop?(_poll_loop), do: false

  defp valid_joypad?(joypad) do
    exact_map_keys?(joypad, [:buttons, :shift, :latch?, :auto?, :results, :busy_from, :busy_until]) and
      tuple_of_words?(joypad.buttons, 2) and tuple_of_words?(joypad.shift, 2) and
      is_boolean(joypad.latch?) and is_boolean(joypad.auto?) and
      tuple_of_words?(joypad.results, 4) and non_negative_integer?(joypad.busy_from) and
      non_negative_integer?(joypad.busy_until)
  end

  defp valid_dma_channels?(channels) when is_tuple(channels) and tuple_size(channels) == 8 do
    channels
    |> Tuple.to_list()
    |> Enum.all?(fn channel ->
      exact_map_keys?(channel, @dma_keys) and
        Enum.all?(
          [
            channel.dmap,
            channel.bbad,
            channel.a_addr,
            channel.a_bank,
            channel.size,
            channel.indirect_bank,
            channel.table_addr,
            channel.line_counter,
            channel.indirect_addr
          ],
          &is_integer/1
        ) and is_boolean(channel.hdma_active?) and is_boolean(channel.hdma_do_transfer?)
    end)
  end

  defp valid_dma_channels?(_channels), do: false

  defp valid_scanline_states?(nil), do: true

  defp valid_scanline_states?(states) when is_list(states) and length(states) <= 239 do
    Enum.all?(states, &valid_visual_state?/1)
  end

  defp valid_scanline_states?(_states), do: false

  defp valid_raster_segments?(segments) when is_map(segments) and map_size(segments) <= 239 do
    Enum.all?(segments, fn
      {line, [{0, _state} | _rest] = transitions}
      when is_integer(line) and line in 0..238 and length(transitions) <= 257 ->
        valid_raster_transitions?(transitions)

      _other ->
        false
    end)
  end

  defp valid_raster_segments?(_segments), do: false

  defp valid_raster_transitions?(transitions) do
    valid? = fn
      {x, state} when is_integer(x) and x in 0..256 -> valid_visual_state?(state)
      _other -> false
    end

    Enum.all?(transitions, valid?) and
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [{first, _state}, {second, _next_state}] -> first < second end)
  end

  defp valid_visual_state?(state),
    do: is_tuple(state) and tuple_size(state) == 40 and array_size?(elem(state, 21), 256)

  defp array_size?(array, expected) do
    try do
      :array.size(array) == expected
    rescue
      _error -> false
    end
  end

  defp tuple_of_bytes?(tuple, size),
    do:
      is_tuple(tuple) and tuple_size(tuple) == size and
        tuple |> Tuple.to_list() |> Enum.all?(&byte?/1)

  defp tuple_of_words?(tuple, size),
    do:
      is_tuple(tuple) and tuple_size(tuple) == size and
        tuple |> Tuple.to_list() |> Enum.all?(&word?/1)

  defp tuple_of_signed_words?(tuple, size),
    do:
      is_tuple(tuple) and tuple_size(tuple) == size and
        tuple |> Tuple.to_list() |> Enum.all?(&signed_word?/1)

  defp tuple_of_signed_bytes?(tuple, size),
    do:
      is_tuple(tuple) and tuple_size(tuple) == size and
        tuple |> Tuple.to_list() |> Enum.all?(&signed_byte?/1)

  defp tuple_of_integers?(tuple, size),
    do:
      is_tuple(tuple) and tuple_size(tuple) == size and
        tuple |> Tuple.to_list() |> Enum.all?(&is_integer/1)

  defp byte?(value), do: integer_between?(value, 0, 0xFF)
  defp signed_byte?(value), do: integer_between?(value, -0x80, 0x7F)
  defp word?(value), do: integer_between?(value, 0, 0xFFFF)

  defp integer_between?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp atomics_to_binary(memory) do
    size = :atomics.info(memory).size
    for index <- 1..size, into: <<>>, do: <<:atomics.get(memory, index)>>
  end

  defp atomics_from_binary(binary) do
    memory = :atomics.new(byte_size(binary), signed: false)

    for <<value <- binary>>, reduce: 1 do
      index ->
        :ok = :atomics.put(memory, index, value)
        index + 1
    end

    memory
  end

  defp exact_struct?(value, module) do
    is_struct(value, module) and
      Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(struct(module)))
  end

  defp exact_map_keys?(map, keys),
    do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp ensure_atoms_loaded do
    for app <- [:beamicom_snes, :nx, :exla] do
      Application.load(app)
      for module <- Application.spec(app, :modules) || [], do: Code.ensure_loaded(module)
    end

    :ok
  end
end
