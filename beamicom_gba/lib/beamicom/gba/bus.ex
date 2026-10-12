defmodule Beamicom.GBA.Bus do
  @moduledoc """
  Game Boy Advance memory map and master-cycle ownership boundary.

  CPU-visible reads and writes advance the same scheduler used by display
  timing. Inspection helpers are side-effect free so tests and renderers do not
  perturb emulated time.
  """

  import Bitwise

  alias Beamicom.GBA.{APU, Cartridge, PPU, Scheduler, Timer}
  alias Beamicom.GBA.Memory.Region

  @ewram_size 256 * 1024
  @iwram_size 32 * 1024
  @palette_size 1024
  @vram_size 96 * 1024
  @oam_size 1024
  @rom_window_size 32 * 1024 * 1024
  @address_mask 0xFFFF_FFFF
  @timer_event_priority 5
  @game_pak_first_cycles {5, 4, 3, 9}
  @game_pak_ws0_second_cycles {3, 2}
  @game_pak_ws1_second_cycles {5, 2}
  @game_pak_ws2_second_cycles {9, 2}

  @compile {:inline,
            game_pak_cycles: 4, read_rom16: 2, read_rom32: 2, bit?: 2, clear_game_pak_prefetch: 1}

  @buttons ~w(a b select start right left up down r l)a
  @dma_defaults {
    %{source: 0, destination: 0, count: 0, control: 0, current_source: 0, current_destination: 0},
    %{source: 0, destination: 0, count: 0, control: 0, current_source: 0, current_destination: 0},
    %{source: 0, destination: 0, count: 0, control: 0, current_source: 0, current_destination: 0},
    %{source: 0, destination: 0, count: 0, control: 0, current_source: 0, current_destination: 0}
  }

  @enforce_keys [
    :bios,
    :cartridge,
    :ewram,
    :iwram,
    :palette,
    :vram,
    :oam,
    :cycle,
    :scheduler,
    :ppu,
    :apu,
    :timers
  ]
  defstruct @enforce_keys ++
              [
                keyinput: 0x03FF,
                dispstat: 0,
                interrupt_enable: 0,
                interrupt_flags: 0,
                interrupt_master_enable: 0,
                waitcnt: 0,
                game_pak_prefetch: {nil, 0, 0},
                dma: @dma_defaults
              ]

  @doc "Creates a powered-on bus and schedules the first HBlank boundary."
  def new(%Cartridge{} = cartridge, opts \\ []) when is_list(opts) do
    bios = Keyword.get(opts, :bios, <<>>)
    ppu = PPU.new(opts)

    scheduler =
      Scheduler.new()
      |> Scheduler.schedule_in(960, 10, :ppu_hblank)

    %__MODULE__{
      bios: bios,
      cartridge: cartridge,
      ewram: Region.new(@ewram_size),
      iwram: Region.new(@iwram_size),
      palette: Region.new(@palette_size),
      vram: Region.new(@vram_size),
      oam: Region.new(@oam_size),
      cycle: 0,
      scheduler: scheduler,
      ppu: ppu,
      apu: APU.new(),
      timers: List.duplicate(Timer.new(), 4) |> List.to_tuple()
    }
  end

  @doc "Returns the current master cycle."
  def cycle(%__MODULE__{cycle: cycle}), do: cycle

  @doc false
  def cycles_until_next_event(%__MODULE__{} = bus) do
    case Scheduler.next_cycle(bus.scheduler) do
      nil -> nil
      cycle -> max(cycle - bus.cycle, 0)
    end
  end

  @doc false
  def acceleration_safe?(%__MODULE__{} = bus, cycles)
      when is_integer(cycles) and cycles >= 0 do
    target = bus.cycle + cycles

    bus.scheduler.events
    |> :gb_sets.to_list()
    |> Enum.take_while(fn {cycle, _priority, _sequence, _tag, _data} -> cycle <= target end)
    |> Enum.all?(&acceleration_safe_event?(bus, &1))
  end

  @doc "Renders stereo host PCM through an exact master-cycle boundary."
  def take_audio(%__MODULE__{} = bus, end_cycle, phase, clock_rate, sample_rate) do
    {apu, sample_count, pcm, phase} =
      APU.render(bus.apu, end_cycle, phase, clock_rate, sample_rate)

    {%{bus | apu: apu}, sample_count, pcm, phase}
  end

  @doc "Returns whether an enabled interrupt source is pending."
  def interrupt_pending?(%__MODULE__{} = bus) do
    bus.interrupt_master_enable != 0 and interrupt_requested?(bus)
  end

  @doc "Returns whether IE and IF share at least one asserted source."
  def interrupt_requested?(%__MODULE__{} = bus),
    do: (bus.interrupt_enable &&& bus.interrupt_flags &&& 0x3FFF) != 0

  @doc "Advances directly to the next scheduled device event."
  def idle_to_next_event(%__MODULE__{} = bus) do
    case Scheduler.next_cycle(bus.scheduler) do
      nil ->
        {idle(bus, 1), 1}

      cycle ->
        elapsed = max(cycle - bus.cycle, 0)
        {idle(bus, elapsed), elapsed}
    end
  end

  @doc "Replaces the complete active-low keypad state."
  def set_buttons(%__MODULE__{} = bus, buttons) when is_list(buttons) do
    pressed = MapSet.new(buttons)

    keyinput =
      @buttons
      |> Enum.with_index()
      |> Enum.reduce(0x03FF, fn {button, bit}, value ->
        if MapSet.member?(pressed, button), do: value &&& bnot(1 <<< bit), else: value
      end)

    %{bus | keyinput: keyinput &&& 0x03FF}
  end

  @doc "Applies the memory and register groups selected by BIOS RegisterRamReset."
  def register_ram_reset(%__MODULE__{} = bus, flags) when flags in 0x00..0xFF do
    bus = %{bus | ppu: PPU.put_dispcnt(bus.ppu, 0x80)}
    bus = if bit?(flags, 0), do: %{bus | ewram: clear_region(bus.ewram)}, else: bus
    bus = if bit?(flags, 1), do: %{bus | iwram: clear_iwram(bus.iwram)}, else: bus
    bus = if bit?(flags, 2), do: %{bus | palette: clear_region(bus.palette)}, else: bus
    bus = if bit?(flags, 3), do: %{bus | vram: clear_region(bus.vram)}, else: bus
    bus = if bit?(flags, 4), do: %{bus | oam: clear_region(bus.oam)}, else: bus

    if bit?(flags, 7), do: reset_io_registers(bus), else: bus
  end

  @doc "Advances device timing by master cycles."
  def idle(%__MODULE__{} = bus, cycles) when is_integer(cycles) and cycles >= 0,
    do: bus |> fill_game_pak_prefetch(cycles) |> advance(cycles)

  @doc "Performs a timed byte read."
  def read8(%__MODULE__{} = bus, address, access \\ :nonsequential)
      when is_integer(address) and access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 1, access)
    {peek8(bus, address), advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc "Performs a timed little-endian halfword read."
  def read16(%__MODULE__{} = bus, address, access \\ :nonsequential)
      when is_integer(address) and access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 2, access)

    {value, bus} =
      if Cartridge.eeprom_address?(bus.cartridge, address) do
        {value, cartridge} = Cartridge.read_eeprom_bit(bus.cartridge)
        {value, %{bus | cartridge: cartridge}}
      else
        {peek16(bus, address), bus}
      end

    {value, advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc false
  def fetch16(
        %__MODULE__{
          game_pak_prefetch: {nil, 0, 0},
          iwram: memory,
          cycle: cycle,
          scheduler: %{deadline: deadline}
        } = bus,
        address,
        access
      )
      when address in 0x0300_0000..0x03FF_FFFF and (address &&& 1) == 0 and
             access in [:nonsequential, :sequential] and
             (is_nil(deadline) or deadline > cycle + 1) do
    value = Region.read16(memory, address - 0x0300_0000)
    {value, %{bus | cycle: cycle + 1}, 1}
  end

  def fetch16(
        %__MODULE__{game_pak_prefetch: {nil, 0, 0}, iwram: memory} = bus,
        address,
        access
      )
      when address in 0x0300_0000..0x03FF_FFFF and (address &&& 1) == 0 and
             access in [:nonsequential, :sequential] do
    value = Region.read16(memory, address - 0x0300_0000)
    {value, advance(bus, 1), 1}
  end

  def fetch16(%__MODULE__{} = bus, address, access)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 1) == 0 and
             access in [:nonsequential, :sequential] do
    {bus, cycles} = game_pak_fetch(bus, address, 2, access)
    value = read_rom16(bus.cartridge.rom, address)
    {value, advance(bus, cycles), cycles}
  end

  def fetch16(%__MODULE__{} = bus, address, access),
    do: bus |> clear_game_pak_prefetch() |> read16(address, access)

  @doc false
  def charge_rom_fetch16(%__MODULE__{} = bus, address, access)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 1) == 0 and
             access in [:nonsequential, :sequential] do
    {bus, cycles} = game_pak_fetch(bus, address, 2, access)
    {advance(bus, cycles), cycles}
  end

  def charge_rom_fetch16(%__MODULE__{} = bus, address, access)
      when is_integer(address) and access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 2, access)
    bus = clear_game_pak_prefetch(bus)
    {advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc false
  def replay_thumb_timing(%__MODULE__{} = bus, target, batch, timing_trace)
      when target in 0x0800_0000..0x0DFF_FFFF and is_integer(batch) and batch > 0 and
             is_list(timing_trace) do
    {bus, iteration_cycles} = replay_thumb_timing_trace(bus, target, timing_trace, 0)
    cycles = iteration_cycles * batch

    {advance(bus, cycles), cycles}
  end

  @doc false
  def replay_thumb_byte_poll_zero_timing(%__MODULE__{} = bus, target, batch)
      when target in 0x0800_0000..0x0DFF_FFFF and is_integer(batch) and batch > 0 do
    {bus, first_fetch} = game_pak_fetch(bus, target, 2, :nonsequential)
    bus = fill_game_pak_prefetch(bus, 1)
    {bus, second_fetch} = game_pak_fetch(bus, target + 2, 2, :sequential)
    {bus, branch_fetch} = game_pak_fetch(bus, target + 4, 2, :sequential)
    cycles = (first_fetch + 1 + second_fetch + branch_fetch) * batch
    {advance(bus, cycles), cycles}
  end

  @doc false
  def replay_thumb_byte_compare_timing(
        %__MODULE__{} = bus,
        target,
        batch,
        left_address,
        right_address
      )
      when target in 0x0800_0000..0x0DFF_FFFF and is_integer(batch) and batch > 0 do
    {bus, first_fetch} = game_pak_fetch(bus, target, 2, :nonsequential)
    left_cycles = access_cycles(bus, left_address, 1, :nonsequential)
    bus = replay_cpu_access(bus, left_address, left_cycles)
    {bus, second_fetch} = game_pak_fetch(bus, target + 2, 2, :sequential)
    right_cycles = access_cycles(bus, right_address, 1, :nonsequential)
    bus = replay_cpu_access(bus, right_address, right_cycles)
    {bus, compare_fetch} = game_pak_fetch(bus, target + 4, 2, :sequential)
    {bus, branch_fetch} = game_pak_fetch(bus, target + 6, 2, :sequential)

    cycles =
      (first_fetch + left_cycles + second_fetch + right_cycles + compare_fetch + branch_fetch) *
        batch

    {advance(bus, cycles), cycles}
  end

  @doc false
  def replay_thumb_timing(%__MODULE__{} = bus, target, timing_traces)
      when target in 0x0800_0000..0x0DFF_FFFF and is_list(timing_traces) do
    {bus, cycles} =
      Enum.reduce(timing_traces, {bus, 0}, fn timing_trace, {bus, cycles} ->
        replay_thumb_timing_trace(bus, target, timing_trace, cycles)
      end)

    {advance(bus, cycles), cycles}
  end

  @doc "Performs a timed word read with ARM7TDMI unaligned rotation."
  def read32(%__MODULE__{} = bus, address, access \\ :nonsequential)
      when is_integer(address) and access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 4, access)
    {peek32(bus, address), advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc false
  def fetch32(
        %__MODULE__{
          game_pak_prefetch: {nil, 0, 0},
          iwram: memory,
          cycle: cycle,
          scheduler: %{deadline: deadline}
        } = bus,
        address,
        access
      )
      when address in 0x0300_0000..0x03FF_FFFF and (address &&& 3) == 0 and
             access in [:nonsequential, :sequential] and
             (is_nil(deadline) or deadline > cycle + 1) do
    value = Region.read32(memory, address - 0x0300_0000)
    {value, %{bus | cycle: cycle + 1}, 1}
  end

  def fetch32(
        %__MODULE__{game_pak_prefetch: {nil, 0, 0}, iwram: memory} = bus,
        address,
        access
      )
      when address in 0x0300_0000..0x03FF_FFFF and (address &&& 3) == 0 and
             access in [:nonsequential, :sequential] do
    value = Region.read32(memory, address - 0x0300_0000)
    {value, advance(bus, 1), 1}
  end

  def fetch32(%__MODULE__{} = bus, address, access)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 3) == 0 and
             access in [:nonsequential, :sequential] do
    {bus, cycles} = game_pak_fetch(bus, address, 4, access)
    value = read_rom32(bus.cartridge.rom, address)
    {value, advance(bus, cycles), cycles}
  end

  def fetch32(%__MODULE__{} = bus, address, access),
    do: bus |> clear_game_pak_prefetch() |> read32(address, access)

  @doc false
  def charge_rom_fetch32(%__MODULE__{} = bus, address, access)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 3) == 0 and
             access in [:nonsequential, :sequential] do
    {bus, cycles} = game_pak_fetch(bus, address, 4, access)
    {advance(bus, cycles), cycles}
  end

  def charge_rom_fetch32(%__MODULE__{} = bus, address, access)
      when is_integer(address) and access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 4, access)
    bus = clear_game_pak_prefetch(bus)
    {advance_cpu_access(bus, address, cycles), cycles}
  end

  def rom_fetch_cycles(%__MODULE__{} = bus, address, width, access)
      when address in 0x0800_0000..0x0DFF_FFFF and width in [1, 2, 4] and
             access in [:nonsequential, :sequential],
      do: game_pak_cycles(bus.waitcnt, address, width, access)

  @doc "Performs a timed byte write."
  def write8(%__MODULE__{} = bus, address, value, access \\ :nonsequential)
      when is_integer(address) and value in 0x00..0xFF and
             access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 1, access)
    bus = bus |> put8(address, value) |> advance_cpu_access(address, cycles)
    {bus, cycles}
  end

  @doc "Performs a timed little-endian halfword write."
  def write16(%__MODULE__{} = bus, address, value, access \\ :nonsequential)
      when is_integer(address) and value in 0x0000..0xFFFF and
             access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 2, access)
    address = address &&& 0xFFFF_FFFE

    bus =
      if Cartridge.eeprom_address?(bus.cartridge, address) do
        %{bus | cartridge: Cartridge.write_eeprom_bit(bus.cartridge, value)}
      else
        put16_raw(bus, address, value)
      end

    {advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc "Performs a timed little-endian word write."
  def write32(%__MODULE__{} = bus, address, value, access \\ :nonsequential)
      when is_integer(address) and value in 0x0000_0000..0xFFFF_FFFF and
             access in [:nonsequential, :sequential] do
    cycles = access_cycles(bus, address, 4, access)
    address = address &&& 0xFFFF_FFFC

    bus = put32_raw(bus, address, value)

    {advance_cpu_access(bus, address, cycles), cycles}
  end

  @doc "Inspects a byte without advancing time."
  def peek8(%__MODULE__{} = bus, address) when address in 0x0000_0000..0x0000_3FFF do
    if address < byte_size(bus.bios), do: :binary.at(bus.bios, address), else: 0xFF
  end

  def peek8(%__MODULE__{ewram: memory}, address) when address in 0x0200_0000..0x02FF_FFFF,
    do: Region.read(memory, address - 0x0200_0000)

  def peek8(%__MODULE__{iwram: memory}, address) when address in 0x0300_0000..0x03FF_FFFF,
    do: Region.read(memory, address - 0x0300_0000)

  def peek8(%__MODULE__{} = bus, 0x0400_0000), do: bus.ppu.dispcnt &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0001), do: bus.ppu.dispcnt >>> 8
  def peek8(%__MODULE__{} = bus, 0x0400_0004), do: display_status(bus) &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0005), do: display_status(bus) >>> 8
  def peek8(%__MODULE__{} = bus, 0x0400_0006), do: bus.ppu.line &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0007), do: bus.ppu.line >>> 8

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_0008..0x0400_001F,
    do: PPU.background_register(bus.ppu, address - 0x0400_0000)

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_0020..0x0400_003F,
    do: PPU.affine_register(bus.ppu, address - 0x0400_0000)

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_0040..0x0400_0055,
    do: PPU.display_effect_register(bus.ppu, address - 0x0400_0000)

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_0060..0x0400_009F,
    do: APU.register(bus.apu, address - 0x0400_0000)

  def peek8(%__MODULE__{}, address) when address in 0x0400_00A0..0x0400_00A7, do: 0

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_0100..0x0400_010F,
    do: timer_register_byte(bus, address)

  def peek8(%__MODULE__{} = bus, 0x0400_0130), do: bus.keyinput &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0131), do: bus.keyinput >>> 8

  def peek8(%__MODULE__{} = bus, address) when address in 0x0400_00B0..0x0400_00DF,
    do: dma_register_byte(bus, address)

  def peek8(%__MODULE__{} = bus, 0x0400_0200), do: bus.interrupt_enable &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0201), do: bus.interrupt_enable >>> 8
  def peek8(%__MODULE__{} = bus, 0x0400_0202), do: bus.interrupt_flags &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0203), do: bus.interrupt_flags >>> 8
  def peek8(%__MODULE__{} = bus, 0x0400_0204), do: bus.waitcnt &&& 0xFF
  def peek8(%__MODULE__{} = bus, 0x0400_0205), do: bus.waitcnt >>> 8
  def peek8(%__MODULE__{} = bus, 0x0400_0208), do: bus.interrupt_master_enable
  def peek8(%__MODULE__{}, address) when address in 0x0400_0209..0x0400_020B, do: 0
  def peek8(%__MODULE__{}, address) when address in 0x0400_0000..0x04FF_FFFF, do: 0

  def peek8(%__MODULE__{palette: memory}, address) when address in 0x0500_0000..0x05FF_FFFF,
    do: Region.read(memory, address - 0x0500_0000)

  def peek8(%__MODULE__{vram: memory}, address) when address in 0x0600_0000..0x06FF_FFFF,
    do: Region.read(memory, vram_offset(address))

  def peek8(%__MODULE__{oam: memory}, address) when address in 0x0700_0000..0x07FF_FFFF,
    do: Region.read(memory, address - 0x0700_0000)

  def peek8(%__MODULE__{cartridge: cartridge}, address)
      when address in 0x0800_0000..0x0DFF_FFFF,
      do: Cartridge.read(cartridge, address)

  def peek8(%__MODULE__{cartridge: cartridge}, address)
      when address in 0x0E00_0000..0x0FFF_FFFF,
      do: Cartridge.read_backup(cartridge, address - 0x0E00_0000)

  def peek8(%__MODULE__{}, address) when address in 0x0000_0000..0xFFFF_FFFF, do: 0xFF

  @doc "Inspects a halfword without advancing time."
  def peek16(%__MODULE__{cartridge: cartridge}, address)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 1) == 0,
      do: Cartridge.read16(cartridge, address)

  def peek16(%__MODULE__{ewram: memory}, address)
      when address in 0x0200_0000..0x02FF_FFFF,
      do: Region.read16(memory, (address &&& 0xFFFF_FFFE) - 0x0200_0000)

  def peek16(%__MODULE__{iwram: memory}, address)
      when address in 0x0300_0000..0x03FF_FFFF,
      do: Region.read16(memory, (address &&& 0xFFFF_FFFE) - 0x0300_0000)

  def peek16(%__MODULE__{palette: memory}, address)
      when address in 0x0500_0000..0x05FF_FFFF,
      do: Region.read16(memory, (address &&& 0xFFFF_FFFE) - 0x0500_0000)

  def peek16(%__MODULE__{vram: memory}, address)
      when address in 0x0600_0000..0x06FF_FFFF,
      do: Region.read16(memory, vram_offset(address &&& 0xFFFF_FFFE))

  def peek16(%__MODULE__{oam: memory}, address)
      when address in 0x0700_0000..0x07FF_FFFF,
      do: Region.read16(memory, (address &&& 0xFFFF_FFFE) - 0x0700_0000)

  def peek16(%__MODULE__{} = bus, address) do
    address = address &&& 0xFFFF_FFFE
    peek8(bus, address) ||| peek8(bus, address + 1) <<< 8
  end

  @doc "Inspects a word without advancing time, including unaligned rotation."
  def peek32(%__MODULE__{cartridge: cartridge}, address)
      when address in 0x0800_0000..0x0DFF_FFFF and (address &&& 3) == 0,
      do: Cartridge.read32(cartridge, address)

  def peek32(%__MODULE__{ewram: memory}, address)
      when address in 0x0200_0000..0x02FF_FFFF do
    aligned = address &&& 0xFFFF_FFFC
    memory |> Region.read32(aligned - 0x0200_0000) |> rotate_right(rem(address, 4) * 8)
  end

  def peek32(%__MODULE__{iwram: memory}, address)
      when address in 0x0300_0000..0x03FF_FFFF do
    aligned = address &&& 0xFFFF_FFFC
    memory |> Region.read32(aligned - 0x0300_0000) |> rotate_right(rem(address, 4) * 8)
  end

  def peek32(%__MODULE__{palette: memory}, address)
      when address in 0x0500_0000..0x05FF_FFFF do
    aligned = address &&& 0xFFFF_FFFC
    memory |> Region.read32(aligned - 0x0500_0000) |> rotate_right(rem(address, 4) * 8)
  end

  def peek32(%__MODULE__{vram: memory}, address)
      when address in 0x0600_0000..0x06FF_FFFF do
    aligned = address &&& 0xFFFF_FFFC
    memory |> Region.read32(vram_offset(aligned)) |> rotate_right(rem(address, 4) * 8)
  end

  def peek32(%__MODULE__{oam: memory}, address)
      when address in 0x0700_0000..0x07FF_FFFF do
    aligned = address &&& 0xFFFF_FFFC
    memory |> Region.read32(aligned - 0x0700_0000) |> rotate_right(rem(address, 4) * 8)
  end

  def peek32(%__MODULE__{} = bus, address) do
    aligned = address &&& 0xFFFF_FFFC

    value =
      peek8(bus, aligned) ||| peek8(bus, aligned + 1) <<< 8 |||
        peek8(bus, aligned + 2) <<< 16 ||| peek8(bus, aligned + 3) <<< 24

    rotate_right(value, rem(address, 4) * 8)
  end

  @doc "Writes a byte without advancing time; intended for loading and tests."
  def put8(%__MODULE__{} = bus, address, value)
      when is_integer(address) and value in 0x00..0xFF do
    put8_mapped(bus, address &&& 0xFFFF_FFFF, value)
  end

  defp put8_mapped(%__MODULE__{ewram: memory} = bus, address, value)
       when address in 0x0200_0000..0x02FF_FFFF,
       do: %{bus | ewram: Region.write(memory, address - 0x0200_0000, value)}

  defp put8_mapped(%__MODULE__{iwram: memory} = bus, address, value)
       when address in 0x0300_0000..0x03FF_FFFF,
       do: %{bus | iwram: Region.write(memory, address - 0x0300_0000, value)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0000, value),
    do: %{bus | ppu: PPU.put_dispcnt(bus.ppu, (bus.ppu.dispcnt &&& 0xFF00) ||| value)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0001, value),
    do: %{bus | ppu: PPU.put_dispcnt(bus.ppu, (bus.ppu.dispcnt &&& 0x00FF) ||| value <<< 8)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0004, value),
    do: %{bus | dispstat: (bus.dispstat &&& 0xFF00) ||| (value &&& 0xF8)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0005, value),
    do: %{bus | dispstat: (bus.dispstat &&& 0x00F8) ||| value <<< 8}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0008..0x0400_001F,
       do: %{bus | ppu: PPU.put_background_register(bus.ppu, address - 0x0400_0000, value)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0020..0x0400_003F,
       do: %{bus | ppu: PPU.put_affine_register(bus.ppu, address - 0x0400_0000, value)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0040..0x0400_0055,
       do: %{bus | ppu: PPU.put_display_effect_register(bus.ppu, address - 0x0400_0000, value)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0060..0x0400_009F,
       do: %{bus | apu: APU.put_register(bus.apu, address - 0x0400_0000, value, bus.cycle)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_00A0..0x0400_00A3,
       do: %{bus | apu: APU.put_fifo(bus.apu, :a, value)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_00A4..0x0400_00A7,
       do: %{bus | apu: APU.put_fifo(bus.apu, :b, value)}

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0100..0x0400_010F,
       do: put_timer_register_byte(bus, address, value)

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0400_00B0..0x0400_00DF,
       do: put_dma_register_byte(bus, address, value)

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0200, value),
    do: %{bus | interrupt_enable: (bus.interrupt_enable &&& 0x3F00) ||| value}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0201, value),
    do: %{bus | interrupt_enable: (bus.interrupt_enable &&& 0x00FF) ||| (value &&& 0x3F) <<< 8}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0202, value),
    do: %{bus | interrupt_flags: bus.interrupt_flags &&& bnot(value)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0203, value),
    do: %{bus | interrupt_flags: bus.interrupt_flags &&& bnot(value <<< 8)}

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0204, value),
    do: put_waitcnt(bus, (bus.waitcnt &&& 0x7F00) ||| value)

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0205, value),
    do: put_waitcnt(bus, (bus.waitcnt &&& 0x00FF) ||| (value &&& 0x7F) <<< 8)

  defp put8_mapped(%__MODULE__{} = bus, 0x0400_0208, value),
    do: %{bus | interrupt_master_enable: value &&& 1}

  defp put8_mapped(%__MODULE__{} = bus, address, _value)
       when address in 0x0400_0209..0x0400_020B,
       do: bus

  defp put8_mapped(%__MODULE__{} = bus, address, _value)
       when address in 0x0400_0000..0x04FF_FFFF,
       do: bus

  defp put8_mapped(%__MODULE__{palette: memory} = bus, address, value)
       when address in 0x0500_0000..0x05FF_FFFF do
    offset = address - 0x0500_0000 &&& 0x3FE
    memory = Region.write16(memory, offset, value ||| value <<< 8)
    %{bus | palette: memory}
  end

  defp put8_mapped(%__MODULE__{vram: memory} = bus, address, value)
       when address in 0x0600_0000..0x06FF_FFFF do
    offset = vram_offset(address) &&& 0x1FFFE
    memory = Region.write16(memory, offset, value ||| value <<< 8)
    %{bus | vram: memory}
  end

  defp put8_mapped(%__MODULE__{} = bus, address, _value)
       when address in 0x0700_0000..0x07FF_FFFF,
       do: bus

  defp put8_mapped(%__MODULE__{} = bus, address, value)
       when address in 0x0E00_0000..0x0FFF_FFFF,
       do: %{bus | cartridge: Cartridge.write_backup(bus.cartridge, address - 0x0E00_0000, value)}

  defp put8_mapped(%__MODULE__{} = bus, _address, _value), do: bus

  defp put_waitcnt(bus, waitcnt),
    do: %{bus | waitcnt: waitcnt, game_pak_prefetch: {nil, 0, 0}}

  defp put8_raw(%__MODULE__{ewram: memory} = bus, address, value)
       when address in 0x0200_0000..0x02FF_FFFF,
       do: %{bus | ewram: Region.write(memory, address - 0x0200_0000, value)}

  defp put8_raw(%__MODULE__{iwram: memory} = bus, address, value)
       when address in 0x0300_0000..0x03FF_FFFF,
       do: %{bus | iwram: Region.write(memory, address - 0x0300_0000, value)}

  defp put8_raw(%__MODULE__{} = bus, address, value)
       when address in 0x0400_0000..0x04FF_FFFF,
       do: put8_mapped(bus, address, value)

  defp put8_raw(%__MODULE__{palette: memory} = bus, address, value)
       when address in 0x0500_0000..0x05FF_FFFF,
       do: %{bus | palette: Region.write(memory, address - 0x0500_0000, value)}

  defp put8_raw(%__MODULE__{vram: memory} = bus, address, value)
       when address in 0x0600_0000..0x06FF_FFFF,
       do: %{bus | vram: Region.write(memory, vram_offset(address), value)}

  defp put8_raw(%__MODULE__{oam: memory} = bus, address, value)
       when address in 0x0700_0000..0x07FF_FFFF,
       do: %{bus | oam: Region.write(memory, address - 0x0700_0000, value)}

  defp put8_raw(%__MODULE__{} = bus, address, value)
       when address in 0x0E00_0000..0x0FFF_FFFF,
       do: %{bus | cartridge: Cartridge.write_backup(bus.cartridge, address - 0x0E00_0000, value)}

  defp put8_raw(%__MODULE__{} = bus, _address, _value), do: bus

  defp put16_raw(%__MODULE__{ewram: memory} = bus, address, value)
       when address in 0x0200_0000..0x02FF_FFFF,
       do: %{bus | ewram: Region.write16(memory, address - 0x0200_0000, value)}

  defp put16_raw(%__MODULE__{iwram: memory} = bus, address, value)
       when address in 0x0300_0000..0x03FF_FFFF,
       do: %{bus | iwram: Region.write16(memory, address - 0x0300_0000, value)}

  defp put16_raw(%__MODULE__{palette: memory} = bus, address, value)
       when address in 0x0500_0000..0x05FF_FFFF,
       do: %{bus | palette: Region.write16(memory, address - 0x0500_0000, value)}

  defp put16_raw(%__MODULE__{vram: memory} = bus, address, value)
       when address in 0x0600_0000..0x06FF_FFFF,
       do: %{bus | vram: Region.write16(memory, vram_offset(address), value)}

  defp put16_raw(%__MODULE__{oam: memory} = bus, address, value)
       when address in 0x0700_0000..0x07FF_FFFF,
       do: %{bus | oam: Region.write16(memory, address - 0x0700_0000, value)}

  defp put16_raw(bus, address, value),
    do: bus |> put8_raw(address, value &&& 0xFF) |> put8_raw(address + 1, value >>> 8)

  defp put32_raw(%__MODULE__{ewram: memory} = bus, address, value)
       when address in 0x0200_0000..0x02FF_FFFF,
       do: %{bus | ewram: Region.write32(memory, address - 0x0200_0000, value)}

  defp put32_raw(%__MODULE__{iwram: memory} = bus, address, value)
       when address in 0x0300_0000..0x03FF_FFFF,
       do: %{bus | iwram: Region.write32(memory, address - 0x0300_0000, value)}

  defp put32_raw(%__MODULE__{palette: memory} = bus, address, value)
       when address in 0x0500_0000..0x05FF_FFFF,
       do: %{bus | palette: Region.write32(memory, address - 0x0500_0000, value)}

  defp put32_raw(%__MODULE__{vram: memory} = bus, address, value)
       when address in 0x0600_0000..0x06FF_FFFF,
       do: %{bus | vram: Region.write32(memory, vram_offset(address), value)}

  defp put32_raw(%__MODULE__{oam: memory} = bus, address, value)
       when address in 0x0700_0000..0x07FF_FFFF,
       do: %{bus | oam: Region.write32(memory, address - 0x0700_0000, value)}

  defp put32_raw(bus, address, value) do
    bus
    |> put8_raw(address, value &&& 0xFF)
    |> put8_raw(address + 1, value >>> 8 &&& 0xFF)
    |> put8_raw(address + 2, value >>> 16 &&& 0xFF)
    |> put8_raw(address + 3, value >>> 24)
  end

  defp advance(bus, 0), do: process_due(bus)

  defp advance(%__MODULE__{} = bus, cycles) do
    scheduler = bus.scheduler
    target = bus.cycle + cycles

    case scheduler.deadline do
      nil ->
        %{bus | cycle: target}

      next when next > target ->
        %{bus | cycle: target}

      next ->
        elapsed = next - bus.cycle
        bus = %{bus | cycle: next} |> process_due()
        advance(bus, cycles - elapsed)
    end
  end

  defp process_due(%__MODULE__{} = bus) do
    scheduler = %{bus.scheduler | now: bus.cycle}
    {scheduler, events} = Scheduler.pop_due(scheduler)
    Enum.reduce(events, %{bus | scheduler: scheduler}, &handle_event/2)
  end

  defp handle_event({:ppu_hblank, _data}, bus) do
    bus =
      %{
        bus
        | ppu: PPU.enter_hblank(bus.ppu),
          scheduler: Scheduler.schedule_in(bus.scheduler, 272, 10, :ppu_line_start)
      }

    bus
    |> request_display_interrupt(4, 1)
    |> run_hblank_dmas()
  end

  defp handle_event({:ppu_line_start, _data}, bus) do
    {vram, palette, oam} =
      if bus.ppu.line == 159,
        do:
          {Region.to_binary(bus.vram), Region.to_binary(bus.palette), Region.to_binary(bus.oam)},
        else: {<<>>, <<>>, <<>>}

    ppu = PPU.begin_next_line(bus.ppu, vram, palette, oam)

    bus =
      %{
        bus
        | ppu: ppu,
          scheduler: Scheduler.schedule_in(bus.scheduler, 960, 10, :ppu_hblank)
      }

    bus
    |> request_vblank_interrupt(ppu.line)
    |> request_vcount_interrupt(ppu.line)
    |> run_vblank_dmas(ppu.line)
  end

  defp handle_event({:timer_reload_write, {index, generation}}, bus) do
    timer = elem(bus.timers, index)

    case Timer.apply_reload(timer, generation) do
      {:applied, timer} -> put_timer(bus, index, timer)
      {:stale, _timer} -> bus
    end
  end

  defp handle_event({:timer_control_write, {index, generation}}, bus) do
    timer = elem(bus.timers, index)

    case Timer.apply_control(timer, generation, bus.cycle) do
      {:applied, timer} -> bus |> put_timer(index, timer) |> schedule_timer_overflow(index)
      {:stale, _timer} -> bus
    end
  end

  defp handle_event({:timer_overflow, {index, generation}}, bus) do
    timer = elem(bus.timers, index)

    if Timer.overflow_current?(timer, generation) do
      timer = Timer.overflow(timer, bus.cycle)

      bus
      |> put_timer(index, timer)
      |> request_timer_interrupt(index, timer)
      |> clock_apu(index)
      |> cascade_timer(index + 1)
      |> schedule_timer_overflow(index)
    else
      bus
    end
  end

  defp display_status(bus) do
    status = if bus.ppu.line >= 160, do: 1, else: 0
    status = if bus.ppu.phase == :hblank, do: status ||| 2, else: status
    compare = bus.dispstat >>> 8
    status = if bus.ppu.line == compare, do: status ||| 4, else: status
    (bus.dispstat &&& 0xFFF8) ||| status
  end

  defp request_vblank_interrupt(bus, 160), do: request_display_interrupt(bus, 3, 0)
  defp request_vblank_interrupt(bus, _line), do: bus

  defp request_vcount_interrupt(bus, line) do
    if line == bus.dispstat >>> 8,
      do: request_display_interrupt(bus, 5, 2),
      else: bus
  end

  defp request_display_interrupt(bus, enable_bit, flag_bit) do
    if (bus.dispstat &&& 1 <<< enable_bit) != 0,
      do: %{bus | interrupt_flags: bus.interrupt_flags ||| 1 <<< flag_bit},
      else: bus
  end

  defp acceleration_safe_event?(bus, {_cycle, _priority, _sequence, :ppu_hblank, _data}) do
    not bit?(bus.dispstat, 4) and
      (bus.ppu.line >= 160 or not dma_timing_enabled?(bus, 2))
  end

  defp acceleration_safe_event?(bus, {_cycle, _priority, _sequence, :ppu_line_start, _data}) do
    line = rem(bus.ppu.line + 1, 228)

    line != 0 and
      (line != 160 or (not bit?(bus.dispstat, 3) and not dma_timing_enabled?(bus, 1))) and
      (line != bus.dispstat >>> 8 or not bit?(bus.dispstat, 5))
  end

  defp acceleration_safe_event?(_bus, _event), do: false

  defp dma_timing_enabled?(bus, timing) do
    bus.dma
    |> Tuple.to_list()
    |> Enum.any?(fn dma -> bit?(dma.control, 15) and dma_timing(dma) == timing end)
  end

  defp run_vblank_dmas(bus, 160), do: run_scheduled_dmas(bus, 1)
  defp run_vblank_dmas(bus, _line), do: bus

  defp run_hblank_dmas(%{ppu: %{line: line}} = bus) when line < 160,
    do: run_scheduled_dmas(bus, 2)

  defp run_hblank_dmas(bus), do: bus

  defp timer_register_byte(bus, address) do
    {index, offset} = timer_location(address)
    timer = elem(bus.timers, index)

    value =
      if offset < 2,
        do: Timer.counter(timer, bus.cycle),
        else: Timer.control(timer)

    value >>> (rem(offset, 2) * 8) &&& 0xFF
  end

  defp put_timer_register_byte(bus, address, byte) do
    {index, offset} = timer_location(address)
    timer = elem(bus.timers, index)

    case offset do
      offset when offset < 2 ->
        {timer, generation} = Timer.queue_reload_byte(timer, offset, byte)

        bus
        |> put_timer(index, timer)
        |> schedule_timer_write(:timer_reload_write, index, generation)

      2 ->
        {timer, generation} = Timer.queue_control(timer, index, byte)

        bus
        |> put_timer(index, timer)
        |> schedule_timer_write(:timer_control_write, index, generation)

      3 ->
        bus
    end
  end

  defp schedule_timer_write(bus, tag, index, generation) do
    scheduler =
      Scheduler.schedule_at(
        bus.scheduler,
        bus.cycle + 1,
        @timer_event_priority,
        tag,
        {index, generation}
      )

    %{bus | scheduler: scheduler}
  end

  defp schedule_timer_overflow(bus, index) do
    timer = elem(bus.timers, index)

    case Timer.next_overflow_cycle(timer, bus.cycle) do
      nil ->
        bus

      cycle ->
        scheduler =
          Scheduler.schedule_at(
            bus.scheduler,
            cycle,
            @timer_event_priority,
            :timer_overflow,
            {index, timer.overflow_generation}
          )

        %{bus | scheduler: scheduler}
    end
  end

  defp request_timer_interrupt(bus, index, timer) do
    if Timer.irq_enabled?(timer),
      do: %{bus | interrupt_flags: bus.interrupt_flags ||| 1 <<< (3 + index)},
      else: bus
  end

  defp cascade_timer(bus, 4), do: bus

  defp cascade_timer(bus, index) do
    timer = elem(bus.timers, index)

    if Timer.enabled?(timer) and Timer.count_up?(timer) do
      case Timer.cascade_tick(timer, bus.cycle) do
        {:tick, timer} ->
          put_timer(bus, index, timer)

        {:overflow, timer} ->
          bus
          |> put_timer(index, timer)
          |> request_timer_interrupt(index, timer)
          |> clock_apu(index)
          |> cascade_timer(index + 1)
      end
    else
      bus
    end
  end

  defp put_timer(bus, index, timer), do: %{bus | timers: put_elem(bus.timers, index, timer)}

  defp clock_apu(bus, index) when index in 0..1 do
    {apu, refills} = APU.timer_overflow(bus.apu, index, bus.cycle)
    Enum.reduce(refills, %{bus | apu: apu}, &run_fifo_dma(&2, &1))
  end

  defp clock_apu(bus, _index), do: bus

  defp timer_location(address) do
    offset = address - 0x0400_0100
    {div(offset, 4), rem(offset, 4)}
  end

  defp reset_io_registers(bus) do
    %{
      bus
      | ppu: PPU.reset_registers(bus.ppu),
        dispstat: 0,
        interrupt_enable: 0,
        interrupt_flags: 0,
        interrupt_master_enable: 0,
        waitcnt: 0,
        dma: @dma_defaults,
        apu: APU.reset_registers(bus.apu, bus.cycle),
        timers: List.duplicate(Timer.new(), 4) |> List.to_tuple()
    }
  end

  defp clear_region(region), do: Region.new(region.size, page_size: region.page_size)

  defp clear_iwram(region) do
    preserved_size = 0x200
    preserved_offset = region.size - preserved_size
    preserved = region |> Region.to_binary() |> binary_part(preserved_offset, preserved_size)
    cleared = :binary.copy(<<0>>, preserved_offset) <> preserved
    Region.from_binary(cleared, page_size: region.page_size)
  end

  defp dma_register_byte(bus, address) do
    {channel, offset} = dma_location(address)
    dma = elem(bus.dma, channel)

    value =
      cond do
        offset < 4 -> dma.source
        offset < 8 -> dma.destination
        offset < 10 -> dma.count
        true -> dma.control
      end

    shift = rem(offset, register_width(offset)) * 8
    value >>> shift &&& 0xFF
  end

  defp register_width(offset) when offset < 4, do: 4
  defp register_width(offset) when offset < 8, do: 4
  defp register_width(_offset), do: 2

  defp put_dma_register_byte(bus, address, byte) do
    {channel, offset} = dma_location(address)
    dma = elem(bus.dma, channel)
    old_control = dma.control

    dma =
      cond do
        offset < 4 -> %{dma | source: put_register_byte(dma.source, offset, byte)}
        offset < 8 -> %{dma | destination: put_register_byte(dma.destination, offset - 4, byte)}
        offset < 10 -> %{dma | count: put_register_byte(dma.count, offset - 8, byte) &&& 0xFFFF}
        true -> %{dma | control: put_register_byte(dma.control, offset - 10, byte) &&& 0xFFFF}
      end

    enabled? = bit?(dma.control, 15)
    was_enabled? = bit?(old_control, 15)

    dma =
      if enabled? and not was_enabled? do
        %{dma | current_source: dma.source, current_destination: dma.destination}
      else
        dma
      end

    bus = %{bus | dma: put_elem(bus.dma, channel, dma)}

    if enabled? and not was_enabled? and dma_timing(dma) == 0,
      do: run_dma(bus, channel),
      else: bus
  end

  defp dma_location(address) do
    offset = address - 0x0400_00B0
    {div(offset, 12), rem(offset, 12)}
  end

  defp put_register_byte(value, byte_index, byte) do
    shift = byte_index * 8
    (value &&& bnot(0xFF <<< shift)) ||| byte <<< shift
  end

  defp run_scheduled_dmas(bus, timing) do
    Enum.reduce(0..3, bus, fn channel, bus ->
      dma = elem(bus.dma, channel)

      if bit?(dma.control, 15) and dma_timing(dma) == timing,
        do: run_dma(bus, channel),
        else: bus
    end)
  end

  defp run_dma(bus, channel) do
    dma = elem(bus.dma, channel)
    width = if bit?(dma.control, 10), do: 4, else: 2
    count = transfer_count(dma.count, channel)
    source_step = address_step(dma.control >>> 7 &&& 0x3, width)
    destination_control = dma.control >>> 5 &&& 0x3
    destination_step = address_step(destination_control, width)

    transfer_cycles =
      dma_transfer_cycles(bus, dma.current_source, dma.current_destination, count, width)

    bus = prepare_backup_dma(bus, dma.current_destination, count)

    {bus, source, destination} =
      run_dma_transfers(
        bus,
        dma.current_source,
        dma.current_destination,
        count,
        width,
        source_step,
        destination_step
      )

    repeat? = bit?(dma.control, 9) and dma_timing(dma) != 0
    control = if repeat?, do: dma.control, else: dma.control &&& bnot(1 <<< 15)

    current_destination =
      if repeat? and destination_control == 3, do: dma.destination, else: destination

    dma =
      %{dma | control: control, current_source: source, current_destination: current_destination}

    bus = charge_dma_cycles(bus, channel, dma, transfer_cycles)

    if bit?(dma.control, 14),
      do: %{bus | interrupt_flags: bus.interrupt_flags ||| 1 <<< (8 + channel)},
      else: bus
  end

  defp run_fifo_dma(bus, fifo) do
    destination = if fifo == :a, do: 0x0400_00A0, else: 0x0400_00A4

    Enum.reduce(1..2, bus, fn channel, bus ->
      dma = elem(bus.dma, channel)

      if bit?(dma.control, 15) and dma_timing(dma) == 3 and
           (dma.current_destination &&& 0xFFFF_FFFC) == destination do
        run_sound_dma(bus, channel)
      else
        bus
      end
    end)
  end

  defp run_sound_dma(bus, channel) do
    dma = elem(bus.dma, channel)
    source_step = address_step(dma.control >>> 7 &&& 0x3, 4)
    transfer_cycles = dma_transfer_cycles(bus, dma.current_source, dma.current_destination, 4, 4)

    {bus, source} =
      case dma_source_binary(bus, dma.current_source, 16, 4, 4, source_step) do
        {:ok, samples} ->
          fifo = if (dma.current_destination &&& 0xFFFF_FFFC) == 0x0400_00A0, do: :a, else: :b
          apu = APU.put_fifo_binary(bus.apu, fifo, samples)
          {%{bus | apu: apu}, advance_dma_address(dma.current_source, source_step, 4)}

        :error ->
          {bus, source, _destination} =
            run_dma_transfers(
              bus,
              dma.current_source,
              dma.current_destination,
              4,
              4,
              source_step,
              0
            )

          {bus, source}
      end

    dma = %{dma | current_source: source, current_destination: dma.destination}
    bus = charge_dma_cycles(bus, channel, dma, transfer_cycles)

    if bit?(dma.control, 14),
      do: %{bus | interrupt_flags: bus.interrupt_flags ||| 1 <<< (8 + channel)},
      else: bus
  end

  defp transfer_count(0, 3), do: 0x1_0000
  defp transfer_count(0, _channel), do: 0x4000
  defp transfer_count(count, _channel), do: count

  defp address_step(0, width), do: width
  defp address_step(1, width), do: -width
  defp address_step(2, _width), do: 0
  defp address_step(3, width), do: width

  # DMA owns the memory bus for the transfer. The first source and destination
  # accesses are non-sequential, later units are sequential, followed by two
  # internal setup cycles (four only for a Game Pak-to-Game Pak transfer).
  defp dma_transfer_cycles(bus, source, destination, count, width) do
    first =
      access_cycles(bus, source, width, :nonsequential) +
        access_cycles(bus, destination, width, :nonsequential)

    sequential =
      access_cycles(bus, source, width, :sequential) +
        access_cycles(bus, destination, width, :sequential)

    internal = if game_pak_address?(source) and game_pak_address?(destination), do: 4, else: 2
    first + (count - 1) * sequential + internal
  end

  # Keep the active channel disabled while device time advances so a long,
  # repeating blanking DMA cannot recursively trigger itself.
  defp charge_dma_cycles(bus, channel, dma, cycles) do
    inactive = %{dma | control: dma.control &&& bnot(1 <<< 15)}
    bus = %{bus | dma: put_elem(bus.dma, channel, inactive)} |> advance(cycles)
    %{bus | dma: put_elem(bus.dma, channel, dma)}
  end

  defp game_pak_address?(address), do: address in 0x0800_0000..0x0DFF_FFFF

  defp run_dma_transfers(
         bus,
         source,
         destination,
         count,
         width,
         source_step,
         destination_step
       ) do
    byte_count = count * width

    with false <- Cartridge.eeprom_address?(bus.cartridge, source),
         false <- Cartridge.eeprom_address?(bus.cartridge, destination),
         true <- destination_step == width,
         true <- rem(destination, width) == 0,
         true <- source_step == 0 or rem(source, width) == 0,
         true <- dma_bulk_safe?(source, destination, byte_count, width, source_step),
         {:ok, binary} <- dma_source_binary(bus, source, byte_count, count, width, source_step),
         {:ok, bus} <- put_dma_binary(bus, destination, binary) do
      {
        bus,
        advance_dma_address(source, source_step, count),
        advance_dma_address(destination, destination_step, count)
      }
    else
      _ ->
        scalar_dma_transfers(
          bus,
          source,
          destination,
          count,
          width,
          source_step,
          destination_step
        )
    end
  end

  defp scalar_dma_transfers(
         bus,
         source,
         destination,
         count,
         width,
         source_step,
         destination_step
       ) do
    Enum.reduce(1..count, {bus, source, destination}, fn _, {bus, source, destination} ->
      bus = dma_transfer(bus, source, destination, width)

      {
        bus,
        advance_dma_address(source, source_step, 1),
        advance_dma_address(destination, destination_step, 1)
      }
    end)
  end

  defp dma_source_binary(bus, source, _byte_count, count, width, 0) do
    unit =
      case width do
        2 -> <<peek16(bus, source)::little-16>>
        4 -> <<peek32(bus, source)::little-32>>
      end

    {:ok, :binary.copy(unit, count)}
  end

  defp dma_source_binary(bus, source, byte_count, _count, width, width),
    do: read_dma_binary(bus, source, byte_count)

  defp dma_source_binary(_bus, _source, _byte_count, _count, _width, _source_step),
    do: :error

  defp read_dma_binary(%__MODULE__{bios: bios}, source, byte_count)
       when source in 0x0000_0000..0x0000_3FFF do
    if source + byte_count <= byte_size(bios),
      do: {:ok, binary_part(bios, source, byte_count)},
      else: :error
  end

  defp read_dma_binary(%__MODULE__{ewram: memory}, source, byte_count)
       when source in 0x0200_0000..0x02FF_FFFF,
       do: {:ok, Region.read_binary(memory, source - 0x0200_0000, byte_count)}

  defp read_dma_binary(%__MODULE__{iwram: memory}, source, byte_count)
       when source in 0x0300_0000..0x03FF_FFFF,
       do: {:ok, Region.read_binary(memory, source - 0x0300_0000, byte_count)}

  defp read_dma_binary(%__MODULE__{palette: memory}, source, byte_count)
       when source in 0x0500_0000..0x05FF_FFFF,
       do: {:ok, Region.read_binary(memory, source - 0x0500_0000, byte_count)}

  defp read_dma_binary(%__MODULE__{oam: memory}, source, byte_count)
       when source in 0x0700_0000..0x07FF_FFFF,
       do: {:ok, Region.read_binary(memory, source - 0x0700_0000, byte_count)}

  defp read_dma_binary(%__MODULE__{cartridge: cartridge}, source, byte_count)
       when source in 0x0800_0000..0x0DFF_FFFF do
    offset = rem(source - 0x0800_0000, 0x0200_0000)

    if offset + byte_count <= byte_size(cartridge.rom),
      do: {:ok, binary_part(cartridge.rom, offset, byte_count)},
      else: :error
  end

  defp read_dma_binary(_bus, _source, _byte_count), do: :error

  defp put_dma_binary(%__MODULE__{ewram: memory} = bus, destination, binary)
       when destination in 0x0200_0000..0x02FF_FFFF,
       do: {:ok, %{bus | ewram: Region.write_binary(memory, destination - 0x0200_0000, binary)}}

  defp put_dma_binary(%__MODULE__{iwram: memory} = bus, destination, binary)
       when destination in 0x0300_0000..0x03FF_FFFF,
       do: {:ok, %{bus | iwram: Region.write_binary(memory, destination - 0x0300_0000, binary)}}

  defp put_dma_binary(%__MODULE__{palette: memory} = bus, destination, binary)
       when destination in 0x0500_0000..0x05FF_FFFF,
       do: {:ok, %{bus | palette: Region.write_binary(memory, destination - 0x0500_0000, binary)}}

  defp put_dma_binary(%__MODULE__{vram: memory} = bus, destination, binary)
       when destination in 0x0600_0000..0x06FF_FFFF,
       do: {:ok, %{bus | vram: write_vram_binary(memory, destination, binary)}}

  defp put_dma_binary(%__MODULE__{oam: memory} = bus, destination, binary)
       when destination in 0x0700_0000..0x07FF_FFFF,
       do: {:ok, %{bus | oam: Region.write_binary(memory, destination - 0x0700_0000, binary)}}

  defp put_dma_binary(_bus, _destination, _binary), do: :error

  defp write_vram_binary(memory, _destination, <<>>), do: memory

  defp write_vram_binary(memory, destination, binary) do
    raw_offset = rem(destination - 0x0600_0000, 0x20_000)

    segment_size =
      if raw_offset < 0x18_000, do: 0x18_000 - raw_offset, else: 0x20_000 - raw_offset

    take = min(byte_size(binary), segment_size)
    <<segment::binary-size(^take), rest::binary>> = binary
    memory = Region.write_binary(memory, vram_offset(destination), segment)
    write_vram_binary(memory, destination + take, rest)
  end

  defp memory_region(address) when address in 0x0000_0000..0x0000_3FFF, do: :bios
  defp memory_region(address) when address in 0x0200_0000..0x02FF_FFFF, do: :ewram
  defp memory_region(address) when address in 0x0300_0000..0x03FF_FFFF, do: :iwram
  defp memory_region(address) when address in 0x0400_0000..0x04FF_FFFF, do: :io
  defp memory_region(address) when address in 0x0500_0000..0x05FF_FFFF, do: :palette
  defp memory_region(address) when address in 0x0600_0000..0x06FF_FFFF, do: :vram
  defp memory_region(address) when address in 0x0700_0000..0x07FF_FFFF, do: :oam
  defp memory_region(address) when address in 0x0800_0000..0x0DFF_FFFF, do: :rom
  defp memory_region(_address), do: :unmapped

  defp dma_bulk_safe?(source, destination, byte_count, width, source_step) do
    source_length = if source_step == 0, do: width, else: byte_count

    with {:ok, {source_region, source_first, source_last}} <-
           dma_physical_span(source, source_length),
         {:ok, {destination_region, destination_first, destination_last}} <-
           dma_physical_span(destination, byte_count) do
      source_region != destination_region or source_last <= destination_first or
        destination_last <= source_first
    else
      :error -> false
    end
  end

  defp dma_physical_span(address, length) do
    case memory_region(address) do
      :bios -> simple_physical_span(:bios, address, length, 0x0000_0000, 16 * 1024)
      :ewram -> simple_physical_span(:ewram, address, length, 0x0200_0000, @ewram_size)
      :iwram -> simple_physical_span(:iwram, address, length, 0x0300_0000, @iwram_size)
      :palette -> simple_physical_span(:palette, address, length, 0x0500_0000, @palette_size)
      :oam -> simple_physical_span(:oam, address, length, 0x0700_0000, @oam_size)
      :rom -> simple_physical_span(:rom, address, length, 0x0800_0000, 0x0200_0000)
      :vram -> vram_physical_span(address, length)
      _other -> :error
    end
  end

  defp simple_physical_span(region, address, length, base, size) do
    offset = rem(address - base, size)

    if offset + length <= size,
      do: {:ok, {region, offset, offset + length}},
      else: :error
  end

  defp vram_physical_span(address, length) do
    raw_offset = rem(address - 0x0600_0000, 0x20_000)
    segment_end = if raw_offset < 0x18_000, do: 0x18_000, else: 0x20_000

    if raw_offset + length <= segment_end do
      offset = vram_offset(address)
      {:ok, {:vram, offset, offset + length}}
    else
      :error
    end
  end

  defp advance_dma_address(address, step, count),
    do: address + step * count &&& @address_mask

  defp dma_transfer(bus, source, destination, 2) do
    {value, bus} = dma_read16(bus, source)
    destination = destination &&& 0xFFFF_FFFE
    dma_write16(bus, destination, value)
  end

  defp dma_transfer(bus, source, destination, 4) do
    value = peek32(bus, source)
    destination = destination &&& 0xFFFF_FFFC
    put32_raw(bus, destination, value)
  end

  defp prepare_backup_dma(bus, destination, count) do
    if Cartridge.eeprom_address?(bus.cartridge, destination),
      do: %{bus | cartridge: Cartridge.begin_eeprom_write(bus.cartridge, count)},
      else: bus
  end

  defp dma_read16(bus, address) do
    if Cartridge.eeprom_address?(bus.cartridge, address) do
      {value, cartridge} = Cartridge.read_eeprom_bit(bus.cartridge)
      {value, %{bus | cartridge: cartridge}}
    else
      {peek16(bus, address), bus}
    end
  end

  defp dma_write16(bus, address, value) do
    if Cartridge.eeprom_address?(bus.cartridge, address) do
      %{bus | cartridge: Cartridge.write_eeprom_bit(bus.cartridge, value)}
    else
      put16_raw(bus, address, value)
    end
  end

  defp dma_timing(dma), do: dma.control >>> 12 &&& 0x3

  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0

  defp access_cycles(bus, address, width, access) do
    cond do
      address in 0x0200_0000..0x02FF_FFFF ->
        if(width == 4, do: 6, else: 3)

      address in 0x0400_0000..0x07FF_FFFF ->
        if(width == 4, do: 2, else: 1)

      address in 0x0800_0000..0x0DFF_FFFF ->
        game_pak_cycles(bus.waitcnt, address, width, access)

      address in 0x0E00_0000..0x0FFF_FFFF ->
        5

      true ->
        1
    end
  end

  defp game_pak_cycles(waitcnt, address, width, access)
       when address in 0x0800_0000..0x09FF_FFFF do
    first = elem(@game_pak_first_cycles, waitcnt >>> 2 &&& 0x3)
    second = elem(@game_pak_ws0_second_cycles, waitcnt >>> 4 &&& 0x1)
    halfword = if access == :sequential, do: second, else: first

    case width do
      4 -> halfword + second
      _byte_or_halfword -> halfword
    end
  end

  defp game_pak_cycles(waitcnt, address, width, access)
       when address in 0x0A00_0000..0x0BFF_FFFF do
    first = elem(@game_pak_first_cycles, waitcnt >>> 5 &&& 0x3)
    second = elem(@game_pak_ws1_second_cycles, waitcnt >>> 7 &&& 0x1)
    halfword = if access == :sequential, do: second, else: first

    case width do
      4 -> halfword + second
      _byte_or_halfword -> halfword
    end
  end

  defp game_pak_cycles(waitcnt, _address, width, access) do
    first = elem(@game_pak_first_cycles, waitcnt >>> 8 &&& 0x3)
    second = elem(@game_pak_ws2_second_cycles, waitcnt >>> 10 &&& 0x1)
    halfword = if access == :sequential, do: second, else: first

    case width do
      4 -> halfword + second
      _byte_or_halfword -> halfword
    end
  end

  defp game_pak_fetch(bus, address, width, access) do
    if bit?(bus.waitcnt, 14) do
      consume_game_pak_prefetch(bus, address, width, access)
    else
      {clear_game_pak_prefetch(bus), game_pak_cycles(bus.waitcnt, address, width, access)}
    end
  end

  defp consume_game_pak_prefetch(bus, address, width, :sequential) do
    units = div(width, 2)

    case bus.game_pak_prefetch do
      {^address, _count, _progress} ->
        consume_game_pak_prefetch_units(bus, units, 0)

      _different_stream ->
        start_game_pak_prefetch(bus, address, width, :sequential)
    end
  end

  defp consume_game_pak_prefetch(bus, address, width, access),
    do: start_game_pak_prefetch(bus, address, width, access)

  defp start_game_pak_prefetch(bus, address, width, access) do
    cycles = game_pak_cycles(bus.waitcnt, address, width, access)
    {%{bus | game_pak_prefetch: {address + width, 0, 0}}, cycles}
  end

  defp consume_game_pak_prefetch_units(bus, 0, cycles), do: {bus, cycles}

  defp consume_game_pak_prefetch_units(
         %{game_pak_prefetch: {address, count, progress}} = bus,
         1,
         cycles
       )
       when count > 0 do
    bus =
      %{bus | game_pak_prefetch: {address + 2, count - 1, progress}}
      |> fill_game_pak_prefetch(1)

    {bus, cycles + 1}
  end

  defp consume_game_pak_prefetch_units(
         %{game_pak_prefetch: {address, 0, progress}} = bus,
         1,
         cycles
       ) do
    sequential = game_pak_cycles(bus.waitcnt, address, 2, :sequential)
    wait = max(sequential - progress, 1)
    {%{bus | game_pak_prefetch: {address + 2, 0, 0}}, cycles + wait}
  end

  defp consume_game_pak_prefetch_units(
         %{game_pak_prefetch: {address, count, progress}} = bus,
         units,
         cycles
       )
       when count > 0 do
    bus =
      %{bus | game_pak_prefetch: {address + 2, count - 1, progress}}
      |> fill_game_pak_prefetch(1)

    consume_game_pak_prefetch_units(bus, units - 1, cycles + 1)
  end

  defp consume_game_pak_prefetch_units(
         %{game_pak_prefetch: {address, 0, progress}} = bus,
         units,
         cycles
       ) do
    sequential = game_pak_cycles(bus.waitcnt, address, 2, :sequential)
    wait = max(sequential - progress, 1)
    bus = %{bus | game_pak_prefetch: {address + 2, 0, 0}}
    consume_game_pak_prefetch_units(bus, units - 1, cycles + wait)
  end

  defp replay_thumb_timing_trace(bus, target, timing_trace, cycles) do
    {bus, cycles, _previous_index} =
      Enum.reduce(timing_trace, {bus, cycles, nil}, fn
        {index, action}, {bus, cycles, previous_index} ->
          access =
            if is_integer(previous_index) and index == previous_index + 1,
              do: :sequential,
              else: :nonsequential

          {bus, fetch_cycles} = game_pak_fetch(bus, target + index * 2, 2, access)
          {bus, action_cycles} = replay_timing_action(bus, action)
          {bus, cycles + fetch_cycles + action_cycles, index}
      end)

    {bus, cycles}
  end

  defp replay_timing_action(bus, nil), do: {bus, 0}

  defp replay_timing_action(bus, {:idle, cycles}),
    do: {fill_game_pak_prefetch(bus, cycles), cycles}

  defp replay_timing_action(bus, {:read8, address}) do
    cycles = access_cycles(bus, address, 1, :nonsequential)
    {replay_cpu_access(bus, address, cycles), cycles}
  end

  defp replay_timing_action(bus, {:read16, address}) do
    cycles = access_cycles(bus, address, 2, :nonsequential)
    {replay_cpu_access(bus, address, cycles), cycles}
  end

  defp replay_cpu_access(bus, address, cycles) when address < 0x0800_0000,
    do: fill_game_pak_prefetch(bus, cycles)

  defp replay_cpu_access(bus, _address, _cycles), do: bus

  defp advance_cpu_access(bus, address, cycles) when address < 0x0800_0000,
    do: bus |> fill_game_pak_prefetch(cycles) |> advance(cycles)

  defp advance_cpu_access(bus, _address, cycles), do: advance(bus, cycles)

  defp fill_game_pak_prefetch(%{game_pak_prefetch: {nil, 0, 0}} = bus, _cycles), do: bus
  defp fill_game_pak_prefetch(bus, 0), do: bus

  defp fill_game_pak_prefetch(bus, cycles) do
    case bus.game_pak_prefetch do
      {_address, 8, _progress} ->
        bus

      {address, count, progress} ->
        sequential = game_pak_cycles(bus.waitcnt, address + count * 2, 2, :sequential)
        elapsed = progress + cycles
        filled = min(div(elapsed, sequential), 8 - count)
        progress = if count + filled == 8, do: 0, else: rem(elapsed, sequential)
        %{bus | game_pak_prefetch: {address, count + filled, progress}}
    end
  end

  defp clear_game_pak_prefetch(%{game_pak_prefetch: {nil, 0, 0}} = bus), do: bus
  defp clear_game_pak_prefetch(bus), do: %{bus | game_pak_prefetch: {nil, 0, 0}}

  defp read_rom16(rom, address) do
    offset = rem(address - 0x0800_0000, @rom_window_size)

    if offset + 2 <= byte_size(rom) do
      <<_::binary-size(^offset), value::little-16, _::binary>> = rom
      value
    else
      read_rom_byte(rom, offset) ||| read_rom_byte(rom, rem(offset + 1, @rom_window_size)) <<< 8
    end
  end

  defp read_rom32(rom, address) do
    offset = rem(address - 0x0800_0000, @rom_window_size)

    if offset + 4 <= byte_size(rom) do
      <<_::binary-size(^offset), value::little-32, _::binary>> = rom
      value
    else
      read_rom_byte(rom, offset) ||| read_rom_byte(rom, rem(offset + 1, @rom_window_size)) <<< 8 |||
        read_rom_byte(rom, rem(offset + 2, @rom_window_size)) <<< 16 |||
        read_rom_byte(rom, rem(offset + 3, @rom_window_size)) <<< 24
    end
  end

  defp read_rom_byte(rom, offset) do
    if offset < byte_size(rom), do: :binary.at(rom, offset), else: 0xFF
  end

  defp vram_offset(address) do
    offset = rem(address - 0x0600_0000, 0x20_000)
    if offset >= 0x18_000, do: offset - 0x8_000, else: offset
  end

  defp rotate_right(value, 0), do: value &&& 0xFFFF_FFFF

  defp rotate_right(value, bits),
    do: (value >>> bits ||| value <<< (32 - bits)) &&& 0xFFFF_FFFF
end
