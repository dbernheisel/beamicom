defmodule Beamicom.GB.SaveState do
  @moduledoc """
  Versioned, ROM-stripped serialization for Game Boy machines.

  The state payload contains every execution-relevant CPU, mapper, timer, PPU,
  and APU field. The immutable cartridge ROM is kept separately and identified
  by its byte length and SHA-256 digest. Completed video and drained PCM are
  transient host output, so they are cleared before serialization.
  """

  import Bitwise

  alias Beamicom.GB.{APU, BoundedZlib, Bus, CPU, Cartridge, Machine, PPU}
  alias Beamicom.GB.APU.{Noise, Pulse, Wave}
  alias Beamicom.GB.Cartridge.{MBC1, MBC2, MBC3, MBC5, RAM}
  alias Beamicom.GB.Cartridge.MBC3.RTC

  @magic "BEAMICOM_GB_STATE"
  @version 1
  @max_state_bytes 4 * 1024 * 1024
  @max_rom_bytes 8 * 1024 * 1024
  @max_compressed_rom_bytes @max_rom_bytes + 1024 * 1024
  @frame_dots 456 * 154
  @apu_clock_rate 4_194_304

  @type identity :: %{size: non_neg_integer(), sha256: binary()}

  @doc "Splits a machine into compressed state and immutable-ROM blobs."
  @spec split(Machine.t()) :: {binary(), binary()}
  def split(%Machine{bus: %{cartridge: %{rom: rom}}} = machine) when is_binary(rom) do
    identity = rom_identity(rom)
    {_count, _pcm, apu} = machine.bus.apu |> APU.flush() |> APU.take_samples()
    apu = snapshot_audio_renderer(apu)
    machine = put_in(machine.bus.apu, apu)

    stripped =
      machine
      |> put_in(
        [Access.key!(:bus), Access.key!(:cartridge)],
        Map.put(machine.bus.cartridge, :rom, <<>>)
      )
      |> put_in(
        [Access.key!(:bus), Access.key!(:ppu), Access.key!(:frame)],
        blank_frame(machine.model)
      )
      |> put_in([Access.key!(:bus), Access.key!(:apu), Access.key!(:samples)], [])
      |> put_in([Access.key!(:bus), Access.key!(:apu), Access.key!(:sample_count)], 0)
      |> put_in([Access.key!(:bus), Access.key!(:serial_output)], [])

    payload = %{magic: @magic, version: @version, rom: identity, machine: stripped}
    {:zlib.compress(:erlang.term_to_binary(payload)), :zlib.compress(rom)}
  end

  @doc "Restores a machine and rejects corrupt, unsupported, or mismatched ROM data."
  @spec merge(binary(), binary()) :: {:ok, Machine.t()} | {:error, term()}
  def merge(state_blob, rom_blob) when is_binary(state_blob) and is_binary(rom_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload),
         {:ok, rom} <- decode_rom(rom_blob),
         :ok <- validate_rom(rom, payload.rom),
         {:ok, machine} <- restore_machine(payload.machine, rom) do
      {:ok, machine}
    end
  end

  @doc "Reads the validated state envelope without requiring the cartridge ROM."
  @spec metadata(binary()) :: {:ok, %{version: pos_integer(), rom: identity()}} | {:error, term()}
  def metadata(state_blob) when is_binary(state_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload) do
      {:ok, %{version: payload.version, rom: payload.rom}}
    end
  end

  @doc "Returns the stable ROM identity used by save states."
  @spec rom_identity(binary()) :: identity()
  def rom_identity(rom) when is_binary(rom),
    do: %{size: byte_size(rom), sha256: :crypto.hash(:sha256, rom)}

  defp decode_state(blob) when byte_size(blob) <= @max_state_bytes do
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

  defp validate_envelope(
         %{
           magic: @magic,
           version: @version,
           rom: %{size: size, sha256: digest},
           machine: %Machine{}
         } =
           payload
       ) do
    valid =
      exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and
        exact_map_keys?(payload.rom, [:size, :sha256]) and
        integer_between?(size, 0, @max_rom_bytes) and sized_binary?(digest, 32)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_envelope(%{magic: @magic, version: version}) when is_integer(version),
    do: {:error, {:unsupported_version, version}}

  defp validate_envelope(_payload), do: {:error, :corrupt}

  defp decode_rom(blob) when byte_size(blob) <= @max_compressed_rom_bytes do
    case BoundedZlib.inflate(blob, @max_rom_bytes) do
      {:ok, rom} -> {:ok, rom}
      {:error, :too_large} -> {:error, :rom_too_large}
      {:error, :invalid} -> {:error, :corrupt_rom}
    end
  end

  defp decode_rom(_blob), do: {:error, :rom_too_large}

  defp validate_rom(rom, expected) do
    if rom_identity(rom) == expected, do: :ok, else: {:error, :rom_mismatch}
  end

  defp restore_machine(
         %Machine{bus: %{cartridge: cartridge}} = machine,
         rom
       )
       when is_struct(cartridge) do
    machine = put_in(machine.bus.cartridge, Map.put(cartridge, :rom, rom))

    case validate_machine(machine, rom) do
      :ok -> {:ok, restore_audio_renderer(machine)}
      {:error, :corrupt} = error -> error
    end
  end

  defp restore_machine(_machine, _rom), do: {:error, :corrupt}

  defp blank_frame(:dmg), do: :binary.copy(<<0>>, 160 * 144)
  defp blank_frame(:cgb), do: :binary.copy(<<255>>, 160 * 144 * 3)

  defp validate_machine(machine, rom) do
    case machine do
      %Machine{cpu: cpu, bus: bus, model: model} ->
        with true <- exact_struct?(machine, Machine),
             true <- model in [:dmg, :cgb],
             :ok <- validate_cpu(cpu),
             :ok <- validate_bus(bus, model, rom) do
          :ok
        else
          _invalid -> {:error, :corrupt}
        end

      _invalid ->
        {:error, :corrupt}
    end
  end

  defp validate_cpu(%CPU{} = cpu) do
    valid =
      exact_struct?(cpu, CPU) and
        Enum.all?([cpu.a, cpu.b, cpu.c, cpu.d, cpu.e, cpu.h, cpu.l], &byte?/1) and
        byte?(cpu.f) and (cpu.f &&& 0x0F) == 0 and word?(cpu.sp) and word?(cpu.pc) and
        cpu.ime_state in [:disabled, :scheduled, :enabled] and
        cpu.run_state in [:running, :halted, :stopped, :locked] and is_boolean(cpu.halt_bug)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_cpu(_cpu), do: {:error, :corrupt}

  defp validate_bus(%Bus{} = bus, model, rom) do
    with true <- exact_struct?(bus, Bus),
         true <- bus.mode == :mapped and is_nil(bus.memory),
         true <- valid_pages?(bus.wram, 128),
         true <- sized_binary?(bus.hram, 0x7F),
         true <- is_binary(bus.boot_rom) and byte_size(bus.boot_rom) <= 0x900,
         true <- is_boolean(bus.boot_enabled),
         true <- not bus.boot_enabled or byte_size(bus.boot_rom) > 0,
         true <- bus.joyp_select in [0, 0x10, 0x20, 0x30],
         true <- byte?(bus.buttons),
         true <- byte?(bus.serial_data) and byte?(bus.serial_control),
         true <- bus.serial_output == [],
         true <- word?(bus.divider),
         true <- Enum.all?([bus.tima, bus.tma, bus.ie, bus.boot_disable], &byte?/1),
         true <- integer_between?(bus.tac, 0, 7),
         true <- integer_between?(bus.timer_reload, 0, 4),
         true <- integer_between?(bus.interrupt_flags, 0, 0x1F),
         true <- integer_between?(bus.control, 0, 0x0F),
         true <- model_control?(model, bus.control),
         true <- integer_between?(bus.svbk, 0, 7),
         true <- is_nil(bus.oam_dma) or byte?(bus.oam_dma),
         true <- byte_tuple?(bus.hdma, 5),
         true <- valid_hdma?(bus.hdma_request, bus.hblank_pending),
         true <- bus.lcd_phase in [0, 1],
         :ok <- validate_ppu(bus.ppu, model),
         :ok <- validate_apu(bus.apu, model),
         :ok <- validate_cartridge(bus.cartridge, rom) do
      :ok
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp validate_bus(_bus, _model, _rom), do: {:error, :corrupt}

  defp validate_ppu(%PPU{} = ppu, model) do
    line_sizes = if model == :cgb, do: [160 * 3, 372, 513], else: [160, 183, 323]

    valid =
      exact_struct?(ppu, PPU) and ppu.model == model and valid_pages?(ppu.vram, 64) and
        sized_binary?(ppu.oam, 160) and ppu.frame == blank_frame(model) and
        valid_binary_list_sizes?(ppu.lines, 144, line_sizes) and byte_tuple?(ppu.registers, 10) and
        integer_between?(ppu.clock, 0, @frame_dots) and non_negative_integer?(ppu.frame_number) and
        integer_between?(ppu.window_line, 0, 144) and is_boolean(ppu.stat_line) and
        ppu.vram_bank in [0, 1] and pair_of_binaries?(ppu.color_ram, 64) and
        pair_of_color_caches?(ppu.color_cache) and valid_color_indexes?(ppu.color_indexes)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_ppu(_ppu, _model), do: {:error, :corrupt}

  defp validate_apu(%APU{} = apu, model) do
    valid =
      exact_struct?(apu, APU) and apu.model == model and is_boolean(apu.master) and
        byte_tuple?(apu.registers, 23) and sized_binary?(apu.wave_ram, 16) and
        valid_pulse?(apu.ch1) and valid_pulse?(apu.ch2) and valid_wave?(apu.ch3) and
        valid_noise?(apu.ch4) and integer_between?(apu.sequencer_phase, 0, 8_191) and
        integer_between?(apu.sequencer_step, 0, 7) and
        integer_between?(apu.sample_phase, 0, @apu_clock_rate - 1) and apu.pending_dots == 0 and
        apu.samples == [] and apu.sample_count == 0 and apu.render_events == [] and
        apu.render_dots == 0 and valid_render_triggers?(apu.render_triggers)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_apu(_apu, _model), do: {:error, :corrupt}

  defp valid_pulse?(%Pulse{} = pulse) do
    exact_struct?(pulse, Pulse) and
      Enum.all?(
        [
          pulse.enabled,
          pulse.dac,
          pulse.length_enable,
          pulse.envelope_add,
          pulse.sweep_negate,
          pulse.sweep_enabled
        ],
        &is_boolean/1
      ) and integer_between?(pulse.length, 0, 64) and integer_between?(pulse.duty, 0, 3) and
      integer_between?(pulse.duty_pos, 0, 7) and integer_between?(pulse.frequency, 0, 2_047) and
      integer_between?(pulse.timer, 1, 8_192) and
      integer_between?(pulse.initial_volume, 0, 15) and integer_between?(pulse.volume, 0, 15) and
      integer_between?(pulse.envelope_period, 0, 7) and
      integer_between?(pulse.envelope_timer, 1, 8) and
      integer_between?(pulse.sweep_period, 0, 7) and integer_between?(pulse.sweep_shift, 0, 7) and
      integer_between?(pulse.sweep_timer, 1, 8) and
      integer_between?(pulse.sweep_shadow, 0, 2_047)
  end

  defp valid_pulse?(_pulse), do: false

  defp valid_wave?(%Wave{} = wave) do
    exact_struct?(wave, Wave) and is_boolean(wave.enabled) and is_boolean(wave.dac) and
      is_boolean(wave.length_enable) and integer_between?(wave.length, 0, 256) and
      integer_between?(wave.level, 0, 3) and integer_between?(wave.frequency, 0, 2_047) and
      integer_between?(wave.timer, 1, 4_096) and integer_between?(wave.position, 0, 31) and
      integer_between?(wave.sample_buffer, 0, 15)
  end

  defp valid_wave?(_wave), do: false

  defp valid_noise?(%Noise{} = noise) do
    exact_struct?(noise, Noise) and
      Enum.all?(
        [noise.enabled, noise.dac, noise.length_enable, noise.envelope_add, noise.width7],
        &is_boolean/1
      ) and integer_between?(noise.length, 0, 64) and
      integer_between?(noise.initial_volume, 0, 15) and integer_between?(noise.volume, 0, 15) and
      integer_between?(noise.envelope_period, 0, 7) and
      integer_between?(noise.envelope_timer, 1, 8) and integer_between?(noise.shift, 0, 15) and
      integer_between?(noise.divisor, 0, 7) and integer_between?(noise.timer, 1, 3_670_016) and
      integer_between?(noise.lfsr, 0, 0x7FFF)
  end

  defp valid_noise?(_noise), do: false

  defp validate_cartridge(cartridge, rom) do
    case Cartridge.load(rom, validate_checksum: false) do
      {:ok, baseline} when baseline.__struct__ == cartridge.__struct__ ->
        validate_mapper(cartridge, baseline, rom)

      _invalid ->
        {:error, :corrupt}
    end
  end

  defp validate_mapper(%Cartridge{} = cart, %Cartridge{} = base, rom) do
    valid =
      exact_struct?(cart, Cartridge) and cart.header == base.header and cart.rom == rom and
        valid_ram?(cart.ram, base.ram.size) and cart.ram_mask == base.ram_mask

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_mapper(%MBC1{} = cart, %MBC1{} = base, rom) do
    ram_bank = if cart.mode == 1, do: cart.bank_high, else: 0

    expected_ram_offset =
      if base.ram_banks == 0, do: 0, else: rem(ram_bank, base.ram_banks) * 32

    valid =
      exact_struct?(cart, MBC1) and static_mapper_fields?(cart, base, rom) and
        cart.ram_mask == base.ram_mask and is_boolean(cart.ram_enabled) and
        integer_between?(cart.rom_bank_low, 1, 31) and integer_between?(cart.bank_high, 0, 3) and
        cart.mode in [0, 1] and
        cart.rom0_offset ==
          rem(if(cart.mode == 1, do: cart.bank_high <<< 5, else: 0), base.rom_banks) * 0x4000 and
        cart.romx_offset ==
          rem(cart.bank_high <<< 5 ||| cart.rom_bank_low, base.rom_banks) * 0x4000 and
        cart.ram_page_offset == expected_ram_offset

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_mapper(%MBC2{} = cart, %MBC2{} = base, rom) do
    valid =
      exact_struct?(cart, MBC2) and cart.header == base.header and cart.rom == rom and
        valid_ram?(cart.ram, base.ram.size) and cart.rom_banks == base.rom_banks and
        is_boolean(cart.ram_enabled) and integer_between?(cart.rom_bank, 1, 15) and
        cart.romx_offset == rem(cart.rom_bank, base.rom_banks) * 0x4000

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_mapper(%MBC3{} = cart, %MBC3{} = base, rom) do
    valid =
      exact_struct?(cart, MBC3) and static_mapper_fields?(cart, base, rom) and
        is_boolean(cart.ram_enabled) and integer_between?(cart.rom_bank, 1, 127) and
        cart.romx_offset == rem(cart.rom_bank, base.rom_banks) * 0x4000 and
        valid_ram_page_offset?(cart.ram_page_offset, base.ram_banks) and
        valid_mbc3_selection?(cart.selection, base.ram_banks, base.rtc) and
        integer_between?(cart.rtc_register, 0x08, 0x0C) and valid_rtc?(cart.rtc, base.rtc) and
        (is_nil(cart.latched_rtc) or valid_rtc?(cart.latched_rtc, base.rtc)) and
        byte?(cart.latch_value)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_mapper(%MBC5{} = cart, %MBC5{} = base, rom) do
    bank = cart.rom_bank_high <<< 8 ||| cart.rom_bank_low

    expected_ram_offset =
      if base.ram_banks == 0, do: 0, else: rem(cart.ram_bank, base.ram_banks) * 32

    valid =
      exact_struct?(cart, MBC5) and static_mapper_fields?(cart, base, rom) and
        cart.ram_bank_mask == base.ram_bank_mask and is_boolean(cart.ram_enabled) and
        byte?(cart.rom_bank_low) and cart.rom_bank_high in [0, 1] and
        integer_between?(cart.ram_bank, 0, base.ram_bank_mask) and is_boolean(cart.rumble) and
        (base.ram_bank_mask == 0x07 or not cart.rumble) and
        cart.romx_offset == rem(bank, base.rom_banks) * 0x4000 and
        cart.ram_page_offset == expected_ram_offset

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_mapper(_cart, _base, _rom), do: {:error, :corrupt}

  defp static_mapper_fields?(cart, base, rom) do
    cart.header == base.header and cart.rom == rom and valid_ram?(cart.ram, base.ram.size) and
      cart.rom_banks == base.rom_banks and cart.ram_banks == base.ram_banks
  end

  defp valid_ram?(%RAM{pages: pages, size: size} = ram, expected_size) do
    exact_struct?(ram, RAM) and size == expected_size and rem(size, 256) == 0 and
      valid_pages?(pages, div(size, 256))
  end

  defp valid_ram?(_ram, _expected_size), do: false

  defp valid_rtc?(nil, nil), do: true

  defp valid_rtc?(%RTC{} = rtc, %RTC{}) do
    exact_struct?(rtc, RTC) and integer_between?(rtc.seconds, 0, 59) and
      integer_between?(rtc.minutes, 0, 59) and integer_between?(rtc.hours, 0, 23) and
      integer_between?(rtc.days, 0, 511) and is_boolean(rtc.halt) and is_boolean(rtc.carry)
  end

  defp valid_rtc?(_rtc, _baseline), do: false

  defp valid_mbc3_selection?(:none, _ram_banks, _rtc), do: true
  defp valid_mbc3_selection?(:ram, ram_banks, _rtc), do: ram_banks > 0
  defp valid_mbc3_selection?(:rtc, _ram_banks, %RTC{}), do: true
  defp valid_mbc3_selection?(_selection, _ram_banks, _rtc), do: false

  defp valid_ram_page_offset?(0, 0), do: true

  defp valid_ram_page_offset?(offset, banks),
    do: integer_between?(offset, 0, (banks - 1) * 32) and rem(offset, 32) == 0

  defp model_control?(:dmg, control), do: (control &&& 0x01) == 0
  defp model_control?(:cgb, control), do: (control &&& 0x01) == 0x01

  defp valid_hdma?(nil, pending), do: pending == 0

  defp valid_hdma?({mode, source, destination, blocks}, pending) do
    mode in [:general, :hblank] and word?(source) and rem(source, 16) == 0 and
      integer_between?(destination, 0x8000, 0x9FF0) and rem(destination, 16) == 0 and
      integer_between?(blocks, 1, 128) and integer_between?(pending, 0, blocks) and
      (mode == :hblank or pending == 0)
  end

  defp valid_hdma?(_request, _pending), do: false

  defp valid_color_indexes?({background, object}),
    do: valid_color_index?(background) and valid_color_index?(object)

  defp valid_color_indexes?(_indexes), do: false

  defp valid_color_index?(index), do: byte?(index) and (index &&& 0x40) == 0

  defp pair_of_binaries?({left, right}, size),
    do: sized_binary?(left, size) and sized_binary?(right, size)

  defp pair_of_binaries?(_pair, _size), do: false

  defp pair_of_color_caches?({background, object}),
    do: color_cache?(background) and color_cache?(object)

  defp pair_of_color_caches?(_pair), do: false

  defp color_cache?(cache) when is_tuple(cache) and tuple_size(cache) == 32,
    do: cache |> Tuple.to_list() |> Enum.all?(&sized_binary?(&1, 3))

  defp color_cache?(_cache), do: false

  defp valid_binary_list_sizes?(values, max_length, sizes) when is_list(values) do
    case bounded_list_length(values, max_length, 0) do
      {:ok, _length} -> Enum.all?(values, &(is_binary(&1) and byte_size(&1) in sizes))
      :error -> false
    end
  end

  defp valid_binary_list_sizes?(_values, _max_length, _sizes), do: false

  defp valid_render_triggers?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &non_negative_integer?/1)

  defp valid_render_triggers?(_value), do: false

  defp snapshot_audio_renderer(%APU{renderer: :native} = apu), do: apu

  defp snapshot_audio_renderer(%APU{} = apu) do
    state =
      if function_exported?(apu.renderer, :snapshot, 1),
        do: apply(apu.renderer, :snapshot, [apu.renderer_state]),
        else: apu.renderer_state

    %{apu | renderer_state: state}
  end

  defp restore_audio_renderer(%Machine{bus: %{apu: %APU{renderer: :native}}} = machine),
    do: machine

  defp restore_audio_renderer(%Machine{bus: %{apu: apu} = bus} = machine) do
    state =
      if function_exported?(apu.renderer, :restore, 1),
        do: apply(apu.renderer, :restore, [apu.renderer_state]),
        else: apu.renderer_state

    %{machine | bus: %{bus | apu: %{apu | renderer_state: state}}}
  end

  defp bounded_list_length([], _max, length), do: {:ok, length}

  defp bounded_list_length([_head | tail], max, length) when length < max,
    do: bounded_list_length(tail, max, length + 1)

  defp bounded_list_length(_improper_or_long, _max, _length), do: :error

  defp valid_pages?(pages, count) when is_tuple(pages) and tuple_size(pages) == count,
    do: pages |> Tuple.to_list() |> Enum.all?(&sized_binary?(&1, 256))

  defp valid_pages?(_pages, _count), do: false

  defp byte_tuple?(tuple, size) when is_tuple(tuple) and tuple_size(tuple) == size,
    do: tuple |> Tuple.to_list() |> Enum.all?(&byte?/1)

  defp byte_tuple?(_tuple, _size), do: false

  defp exact_struct?(value, module) when is_struct(value, module) do
    template = struct(module)

    map_size(value) == map_size(template) and
      Enum.all?(Map.keys(template), &Map.has_key?(value, &1))
  end

  defp exact_struct?(_value, _module), do: false

  defp exact_map_keys?(value, keys) when is_map(value) do
    map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp sized_binary?(value, size), do: is_binary(value) and byte_size(value) == size
  defp byte?(value), do: integer_between?(value, 0, 0xFF)
  defp word?(value), do: integer_between?(value, 0, 0xFFFF)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp integer_between?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp ensure_atoms_loaded do
    Application.load(:beamicom_gbc)
    for module <- Application.spec(:beamicom_gbc, :modules) || [], do: Code.ensure_loaded(module)
    :ok
  end
end
