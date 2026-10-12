defmodule Beamicom.GBA.SaveState do
  @moduledoc """
  Versioned, ROM-stripped serialization for Game Boy Advance machines.

  The execution state retains CPU, memory, device, scheduler, backup, and
  in-flight audio state. Immutable ROM data is stored separately, while the
  completed video frame and decoded-block cache are regenerated after load.
  """

  import Bitwise

  alias Beamicom.GBA.{APU, Backup, BoundedZlib, Bus, CPU, Cartridge, Machine, PPU, Scheduler}
  alias Beamicom.GBA.APU.PSG
  alias Beamicom.GBA.CPU.{ArmLoop, BlockCache, ThumbLoop}
  alias Beamicom.GBA.Memory.Region

  @magic "BEAMICOM_GBA_STATE"
  @version 5
  @maximum_compressed_state_bytes 4 * 1024 * 1024
  @maximum_state_bytes 8 * 1024 * 1024
  @maximum_rom_bytes 32 * 1024 * 1024
  @maximum_compressed_rom_bytes @maximum_rom_bytes + 1024 * 1024
  @blank_frame :binary.copy(<<0>>, 240 * 160 * 3)
  @region_sizes %{ewram: 256 * 1024, iwram: 32 * 1024, palette: 1024, vram: 96 * 1024, oam: 1024}
  @backup_sizes %{
    none: 0,
    sram: 32 * 1024,
    flash512: 64 * 1024,
    flash1m: 128 * 1024,
    eeprom: 8 * 1024
  }
  @legacy_ppu_keys [
    :__struct__,
    :bg_affine,
    :bgcnt,
    :bghofs,
    :bgvofs,
    :dispcnt,
    :display_effects,
    :frame,
    :frame_number,
    :line,
    :phase,
    :renderer,
    :scanline_bgcnt
  ]
  @loaded_modules [
    APU,
    PSG,
    Backup,
    Bus,
    CPU,
    Cartridge,
    Machine,
    PPU,
    Scheduler,
    Beamicom.GBA.Timer,
    ArmLoop,
    BlockCache,
    Region,
    ThumbLoop
  ]

  @doc "Splits a machine into compressed state and immutable-ROM blobs."
  def split(%Machine{bus: %{cartridge: %Cartridge{rom: rom}}} = machine)
      when is_binary(rom) do
    identity = rom_identity(rom)
    cartridge = %{machine.bus.cartridge | rom: <<>>}
    ppu = %{machine.bus.ppu | frame: @blank_frame}
    bus = %{machine.bus | cartridge: cartridge, ppu: ppu}

    block_cache = BlockCache.new(limit: machine.block_cache.limit)
    stripped = %{machine | bus: bus, block_cache: block_cache}
    payload = %{magic: @magic, version: @version, rom: identity, machine: stripped}

    {:zlib.compress(:erlang.term_to_binary(payload)), :zlib.compress(rom)}
  end

  @doc "Restores a machine and rejects corrupt, unsupported, or mismatched ROM data."
  def merge(state_blob, rom_blob) when is_binary(state_blob) and is_binary(rom_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         {:ok, payload} <- upgrade_payload(payload),
         :ok <- validate_envelope(payload),
         {:ok, rom} <- decode_rom(rom_blob),
         :ok <- validate_rom(rom, payload.rom),
         {:ok, machine} <- safely_restore_machine(payload.machine, rom) do
      {:ok, machine}
    end
  end

  @doc "Reads the validated state metadata without requiring the cartridge ROM."
  def metadata(state_blob) when is_binary(state_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         {:ok, payload} <- upgrade_payload(payload),
         :ok <- validate_envelope(payload) do
      {:ok, %{version: payload.version, rom: payload.rom}}
    end
  end

  @doc "Returns the stable identity stored alongside a save state's ROM."
  def rom_identity(rom) when is_binary(rom),
    do: %{size: byte_size(rom), sha256: :crypto.hash(:sha256, rom)}

  defp decode_state(blob) when byte_size(blob) <= @maximum_compressed_state_bytes do
    with {:ok, inflated} <- BoundedZlib.inflate(blob, @maximum_state_bytes) do
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

  defp upgrade_payload(
         %{
           magic: @magic,
           version: 4,
           machine: %Machine{bus: %Bus{apu: %APU{} = apu} = bus} = machine
         } = payload
       ) do
    if exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and legacy_apu?(apu) do
      bus = %{bus | apu: upgrade_legacy_apu(apu)}
      {:ok, %{payload | version: @version, machine: %{machine | bus: bus}}}
    else
      {:error, :corrupt}
    end
  end

  defp upgrade_payload(
         %{
           magic: @magic,
           version: 1,
           machine: %Machine{bus: %Bus{ppu: %PPU{} = ppu} = bus} = machine
         } = payload
       ) do
    if exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and legacy_ppu?(ppu) and
         legacy_bus?(bus) do
      ppu = upgrade_legacy_ppu(ppu)
      bus = bus |> upgrade_legacy_bus() |> Map.put(:ppu, ppu)
      {:ok, %{payload | version: @version, machine: %{machine | bus: bus}}}
    else
      {:error, :corrupt}
    end
  end

  defp upgrade_payload(
         %{
           magic: @magic,
           version: 3,
           machine: %Machine{bus: %Bus{} = bus} = machine
         } = payload
       ) do
    if exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and
         legacy_prefetch_bus?(bus) do
      bus = upgrade_legacy_bus(bus)
      {:ok, %{payload | version: @version, machine: %{machine | bus: bus}}}
    else
      {:error, :corrupt}
    end
  end

  defp upgrade_payload(
         %{
           magic: @magic,
           version: 2,
           machine: %Machine{bus: %Bus{} = bus} = machine
         } = payload
       ) do
    if exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and legacy_bus?(bus) do
      bus = upgrade_legacy_bus(bus)
      {:ok, %{payload | version: @version, machine: %{machine | bus: bus}}}
    else
      {:error, :corrupt}
    end
  end

  defp upgrade_payload(payload), do: {:ok, payload}

  defp upgrade_legacy_ppu(ppu) do
    ppu = struct(PPU, Map.from_struct(ppu))
    internal = affine_references(ppu.bg_affine)

    %{
      ppu
      | bg_affine_internal: internal,
        scanline_dispcnt: repeated(ppu.dispcnt),
        scanline_bghofs: repeated(ppu.bghofs),
        scanline_bgvofs: repeated(ppu.bgvofs),
        scanline_bg_affine: repeated(ppu.bg_affine),
        scanline_display_effects: repeated(ppu.display_effects)
    }
  end

  defp legacy_ppu?(ppu), do: Enum.sort(Map.keys(ppu)) == Enum.sort(@legacy_ppu_keys)

  defp legacy_bus?(bus) do
    expected_keys =
      Bus.__struct__() |> Map.keys() |> List.delete(:waitcnt) |> List.delete(:game_pak_prefetch)

    Enum.sort(Map.keys(bus)) == Enum.sort(expected_keys)
  end

  defp legacy_prefetch_bus?(bus) do
    expected_keys = Bus.__struct__() |> Map.keys() |> List.delete(:game_pak_prefetch)
    Enum.sort(Map.keys(bus)) == Enum.sort(expected_keys)
  end

  defp upgrade_legacy_bus(bus) do
    bus = struct(Bus, Map.from_struct(bus))
    %{bus | apu: upgrade_legacy_apu(bus.apu)}
  end

  defp upgrade_legacy_apu(%APU{} = apu) do
    if legacy_apu?(apu) do
      apu = struct(APU, Map.from_struct(apu))

      psg = %{
        PSG.new(apu.render_cycle)
        | master: (apu.soundcnt_x &&& 0x80) != 0,
          soundcnt_l: apu.soundcnt_l,
          soundcnt_h: apu.soundcnt_h
      }

      %{apu | psg: psg}
    else
      apu
    end
  end

  defp legacy_apu?(%APU{} = apu) do
    expected_keys =
      APU.__struct__()
      |> Map.keys()
      |> Kernel.--([:psg_registers, :wave_ram, :psg_events, :psg])

    Enum.sort(Map.keys(apu)) == Enum.sort(expected_keys)
  end

  defp affine_references(affine) do
    affine
    |> Tuple.to_list()
    |> Enum.map(fn {_pa, _pb, _pc, _pd, x, y} -> {x, y} end)
    |> List.to_tuple()
  end

  defp repeated(value), do: List.duplicate(value, 160) |> List.to_tuple()

  defp decode_rom(blob) when byte_size(blob) <= @maximum_compressed_rom_bytes do
    case BoundedZlib.inflate(blob, @maximum_rom_bytes) do
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
           machine: %Machine{} = machine
         } = payload
       ) do
    valid =
      exact_map_keys?(payload, [:magic, :version, :rom, :machine]) and
        exact_map_keys?(payload.rom, [:size, :sha256]) and
        size in 0..@maximum_rom_bytes and is_binary(digest) and byte_size(digest) == 32 and
        safely_valid_machine?(machine)

    if valid, do: :ok, else: {:error, :corrupt}
  end

  defp validate_envelope(%{magic: @magic, version: version}) when is_integer(version),
    do: {:error, {:unsupported_version, version}}

  defp validate_envelope(_payload), do: {:error, :corrupt}

  defp validate_rom(rom, expected) do
    if rom_identity(rom) == expected, do: :ok, else: {:error, :rom_mismatch}
  end

  defp restore_machine(%Machine{bus: %{cartridge: cartridge}} = machine, rom) do
    with {:ok, baseline} <- Cartridge.load(rom, validate_checksum: false),
         true <- static_cartridge?(cartridge, baseline),
         true <- valid_backup?(cartridge.backup, baseline.backup.type) do
      cartridge = %{cartridge | rom: rom}
      block_cache = BlockCache.new(limit: machine.block_cache.limit)

      {:ok,
       %{
         machine
         | bus: %{machine.bus | cartridge: cartridge},
           cpu_executor: Machine.default_cpu_executor(),
           block_cache: block_cache
       }}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp restore_machine(_machine, _rom), do: {:error, :corrupt}

  defp safely_restore_machine(machine, rom) do
    restore_machine(machine, rom)
  rescue
    _error -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  defp safely_valid_machine?(machine) do
    valid_machine?(machine)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_machine?(%Machine{} = machine) do
    exact_struct?(machine, Machine) and machine.cpu_executor in [:scalar, :decoded_blocks] and
      is_integer(machine.audio_phase) and machine.audio_phase >= 0 and
      valid_cpu?(machine.cpu) and valid_bus?(machine.bus) and
      valid_block_cache?(machine.block_cache)
  end

  defp valid_cpu?(%CPU{} = cpu) do
    exact_struct?(cpu, CPU) and tuple_size(cpu.registers) == 16 and
      Enum.all?(Tuple.to_list(cpu.registers), &word?/1) and word?(cpu.pc) and word?(cpu.cpsr) and
      is_map(cpu.banked) and is_map(cpu.spsr) and
      valid_run_state?(cpu.run_state) and cpu.next_fetch in [:nonsequential, :sequential] and
      is_boolean(cpu.fast_loops?)
  end

  defp valid_cpu?(_cpu), do: false

  defp valid_run_state?(:running), do: true
  defp valid_run_state?(:halted), do: true
  defp valid_run_state?({:interrupt_wait, mask}), do: is_integer(mask) and mask in 0..0x3FFF

  defp valid_run_state?({:interrupt_wait_irq, mask, pc, cpsr}),
    do: is_integer(mask) and mask in 0..0x3FFF and word?(pc) and word?(cpsr)

  defp valid_run_state?(_state), do: false

  defp valid_bus?(%Bus{} = bus) do
    exact_struct?(bus, Bus) and is_binary(bus.bios) and byte_size(bus.bios) in [0, 16 * 1024] and
      valid_cartridge?(bus.cartridge) and valid_region?(bus.ewram, @region_sizes.ewram) and
      valid_region?(bus.iwram, @region_sizes.iwram) and
      valid_region?(bus.palette, @region_sizes.palette) and
      valid_region?(bus.vram, @region_sizes.vram) and
      valid_region?(bus.oam, @region_sizes.oam) and non_negative_integer?(bus.cycle) and
      valid_scheduler?(bus.scheduler, bus.cycle) and valid_ppu?(bus.ppu) and valid_apu?(bus.apu) and
      valid_timers?(bus.timers) and valid_dma?(bus.dma) and is_integer(bus.keyinput) and
      is_integer(bus.dispstat) and is_integer(bus.interrupt_enable) and
      is_integer(bus.interrupt_flags) and is_integer(bus.interrupt_master_enable) and
      bus.waitcnt in 0..0x7FFF and valid_game_pak_prefetch?(bus.game_pak_prefetch)
  end

  defp valid_bus?(_bus), do: false

  defp valid_game_pak_prefetch?({nil, 0, 0}), do: true

  defp valid_game_pak_prefetch?({address, count, cycles}),
    do:
      is_integer(address) and address in 0x0800_0000..0x0E00_0000 and rem(address, 2) == 0 and
        count in 0..8 and cycles in 0..8

  defp valid_game_pak_prefetch?(_prefetch), do: false

  defp valid_cartridge?(%Cartridge{rom: <<>>, backup: %Backup{}} = cartridge),
    do: exact_struct?(cartridge, Cartridge)

  defp valid_cartridge?(_cartridge), do: false

  defp valid_region?(%Region{} = region, expected_size) do
    exact_struct?(region, Region) and region.size == expected_size and
      positive_integer?(region.page_size) and rem(region.size, region.page_size) == 0 and
      is_tuple(region.pages) and tuple_size(region.pages) == div(region.size, region.page_size) and
      Enum.all?(Tuple.to_list(region.pages), fn page ->
        is_binary(page) and byte_size(page) == region.page_size
      end)
  end

  defp valid_region?(_region, _expected_size), do: false

  defp valid_scheduler?(%Scheduler{} = scheduler, cycle) do
    events = :gb_sets.to_list(scheduler.events)
    deadline = if events == [], do: nil, else: events |> hd() |> elem(0)

    exact_struct?(scheduler, Scheduler) and non_negative_integer?(scheduler.now) and
      scheduler.now <= cycle and non_negative_integer?(scheduler.next_sequence) and
      scheduler.deadline == deadline and valid_scheduler_events?(events, cycle)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_scheduler?(_scheduler, _cycle), do: false

  defp valid_scheduler_events?(events, bus_cycle) do
    Enum.all?(events, fn
      {cycle, priority, sequence, tag, _data} ->
        non_negative_integer?(cycle) and cycle >= bus_cycle and is_integer(priority) and
          non_negative_integer?(sequence) and is_atom(tag)

      _event ->
        false
    end)
  end

  defp valid_ppu?(%PPU{} = ppu) do
    exact_struct?(ppu, PPU) and ppu.frame == @blank_frame and ppu.line in 0..227 and
      ppu.phase in [:hdraw, :hblank, :vblank] and non_negative_integer?(ppu.frame_number) and
      ppu.renderer in [Beamicom.GBA.ScalarPPURenderer, Beamicom.GBA.Nx.PPURenderer]
  end

  defp valid_ppu?(_ppu), do: false

  defp valid_apu?(%APU{} = apu) do
    exact_struct?(apu, APU) and is_binary(apu.fifo_a) and byte_size(apu.fifo_a) <= 32 and
      is_binary(apu.fifo_b) and byte_size(apu.fifo_b) <= 32 and is_list(apu.events) and
      is_binary(apu.psg_registers) and byte_size(apu.psg_registers) == 32 and
      is_binary(apu.wave_ram) and byte_size(apu.wave_ram) == 32 and is_list(apu.psg_events) and
      exact_struct?(apu.psg, PSG) and non_negative_integer?(apu.render_cycle) and
      apu.psg.cycle == apu.render_cycle
  end

  defp valid_apu?(_apu), do: false

  defp valid_timers?(timers) when is_tuple(timers) and tuple_size(timers) == 4,
    do: Enum.all?(Tuple.to_list(timers), &exact_struct?(&1, Beamicom.GBA.Timer))

  defp valid_timers?(_timers), do: false

  defp valid_dma?(dma) when is_tuple(dma) and tuple_size(dma) == 4,
    do: Enum.all?(Tuple.to_list(dma), &is_map/1)

  defp valid_dma?(_dma), do: false

  defp valid_block_cache?(%BlockCache{} = cache),
    do:
      exact_struct?(cache, BlockCache) and non_negative_integer?(cache.limit) and
        BlockCache.size(cache) == 0

  defp valid_block_cache?(_cache), do: false

  defp static_cartridge?(saved, baseline) do
    saved
    |> Map.from_struct()
    |> Map.drop([:rom, :backup])
    |> Kernel.==(baseline |> Map.from_struct() |> Map.drop([:rom, :backup]))
  end

  defp valid_backup?(%Backup{} = backup, type)
       when type in [:none, :sram, :flash512, :flash1m, :eeprom] do
    expected_size = Map.fetch!(@backup_sizes, type)

    exact_struct?(backup, Backup) and backup.type == type and
      valid_backup_data?(backup.data, expected_size)
  end

  defp valid_backup?(_backup, _type), do: false

  defp valid_backup_data?(nil, 0), do: true
  defp valid_backup_data?(%Region{} = region, size), do: valid_region?(region, size)
  defp valid_backup_data?(_data, _size), do: false

  defp exact_struct?(%{} = value, module) do
    actual_keys = value |> Map.keys() |> Enum.sort()
    expected_keys = module.__struct__() |> Map.keys() |> Enum.sort()
    is_struct(value, module) and actual_keys == expected_keys
  end

  defp exact_struct?(_value, _module), do: false

  defp exact_map_keys?(%{} = map, keys) do
    actual_keys = map |> Map.keys() |> Enum.sort()
    actual_keys == Enum.sort(keys)
  end

  defp word?(value), do: is_integer(value) and value in 0..0xFFFF_FFFF
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp ensure_atoms_loaded do
    Enum.each(@loaded_modules, &Code.ensure_loaded/1)
  end
end
