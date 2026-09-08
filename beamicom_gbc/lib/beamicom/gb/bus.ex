defmodule Beamicom.GB.Bus do
  @moduledoc """
  Concrete CPU bus for Game Boy and Game Boy Color machines.

  Production buses map a `Beamicom.GB.Cartridge` and the sole PPU and APU
  instances together with banked WRAM, HRAM, boot ROM, and implemented I/O
  registers. VRAM, OAM, LCD registers, VBK, and audio registers are routed
  directly to their devices instead of mirrored here. `new_flat/2` is a
  deliberately separate 64 KiB test path used by isolated SM83 tests; `new/2`
  accepts a binary as a compatibility shorthand for that path.

  `tick/2` advances timers in CPU T-cycles and the PPU/APU in base hardware
  dots (four per normal-speed M-cycle, two in double speed). `read_cycle/2`,
  `write_cycle/3`, and `idle/2` retain the CPU's ordered M-cycle contract. OAM
  DMA requests are executed in machine-sized batches: OAM DMA copies 160 bytes,
  while CGB general/HBlank DMA copies 16-byte VRAM blocks. `run_dma/2` advances
  the timer and LCD clock for CPU stalls and returns their M-cycle cost.

  A prepared CGB speed switch currently toggles at the STOP instruction
  boundary. The hardware's 2050-M-cycle oscillator pause and its mode-dependent
  PPU memory-freeze effects are not modeled yet.
  """

  import Bitwise
  alias Beamicom.GB.{APU, Cartridge, PPU}

  @cgb 0x01
  @double_speed 0x02
  @prepare_speed 0x04
  @stop_wake 0x08

  @interrupt_vblank 0x01
  @interrupt_lcd_stat 0x02
  @interrupt_timer 0x04
  @interrupt_serial 0x08
  @interrupt_joypad 0x10

  @timer_periods {1024, 16, 64, 256}
  @dots_per_line 456
  @lines_per_frame 154
  @visible_lines 144
  @hblank_dot 252
  @frame_dots @dots_per_line * @lines_per_frame
  @zero_page :binary.copy(<<0>>, 0x100)
  @zero_wram List.duplicate(@zero_page, 128) |> List.to_tuple()
  @zero_hram :binary.copy(<<0>>, 0x7F)

  defstruct mode: :mapped,
            memory: nil,
            cartridge: nil,
            ppu: nil,
            apu: nil,
            wram: @zero_wram,
            hram: @zero_hram,
            boot_rom: <<>>,
            boot_enabled: false,
            joyp_select: 0x30,
            buttons: 0,
            serial_data: 0,
            serial_control: 0,
            serial_output: [],
            divider: 0,
            tima: 0,
            tma: 0,
            tac: 0,
            timer_reload: 0,
            interrupt_flags: 0,
            ie: 0,
            control: 0,
            svbk: 0,
            oam_dma: nil,
            hdma: {0, 0, 0, 0, 0xFF},
            hdma_request: nil,
            hblank_pending: 0,
            boot_disable: 0,
            lcd_phase: 0

  @compile {:inline,
            read: 2,
            write: 3,
            read_cycle: 2,
            write_cycle: 3,
            idle: 2,
            pending_interrupts: 1,
            double_speed?: 1,
            cgb?: 1,
            timer_input: 2,
            selected_wram_bank: 1,
            paged_byte: 2}

  @type model :: :dmg | :cgb
  @type interrupt :: :vblank | :lcd_stat | :timer | :serial | :joypad
  @type dma_mode :: :general | :hblank
  @type hdma_request :: {dma_mode(), 0..0xFFFF, 0x8000..0x9FF0, 1..128}

  @type t :: %__MODULE__{
          mode: :mapped | :flat,
          memory: :array.array(byte()) | nil,
          cartridge: Cartridge.t() | nil,
          ppu: PPU.t() | nil,
          apu: APU.t() | nil,
          wram: tuple(),
          hram: binary(),
          boot_rom: binary(),
          boot_enabled: boolean(),
          joyp_select: 0..0x30,
          buttons: byte(),
          serial_data: byte(),
          serial_control: byte(),
          serial_output: [byte()],
          divider: 0..0xFFFF,
          tima: byte(),
          tma: byte(),
          tac: 0..7,
          timer_reload: 0..4,
          interrupt_flags: 0..0x1F,
          ie: byte(),
          control: byte(),
          svbk: 0..7,
          oam_dma: byte() | nil,
          hdma: tuple(),
          hdma_request: hdma_request() | nil,
          hblank_pending: non_neg_integer(),
          boot_disable: byte(),
          lcd_phase: 0 | 1
        }

  @doc "Creates a production mapped bus from a cartridge, or a flat test bus from a binary."
  @spec new(Cartridge.t() | binary(), keyword()) :: t()
  def new(source \\ <<>>, opts \\ [])

  def new(%{header: %Beamicom.GB.Header{}} = cartridge, opts) do
    model = Keyword.get(opts, :model, cartridge_model(cartridge))
    boot_rom = Keyword.get(opts, :boot_rom, <<>>)

    unless model in [:dmg, :cgb], do: raise(ArgumentError, "model must be :dmg or :cgb")
    unless is_binary(boot_rom), do: raise(ArgumentError, "boot_rom must be a binary")

    %__MODULE__{
      cartridge: cartridge,
      ppu: PPU.new(model: model, lcdc: 0),
      apu: APU.new(model: model),
      boot_rom: boot_rom,
      boot_enabled: byte_size(boot_rom) > 0,
      control: if(model == :cgb, do: @cgb, else: 0)
    }
  end

  def new(contents, opts) when is_binary(contents), do: new_flat(contents, opts)

  @doc "Creates the flat 64 KiB bus used only for isolated CPU tests."
  @spec new_flat(binary(), keyword()) :: t()
  def new_flat(contents \\ <<>>, opts \\ [])
      when is_binary(contents) and byte_size(contents) <= 0x10000 do
    control = if Keyword.get(opts, :model, :dmg) == :cgb, do: @cgb, else: 0

    %__MODULE__{mode: :flat, memory: :array.new(0x10000, default: 0), control: control}
    |> load(0, contents)
  end

  @doc "Loads bytes into a flat test bus without wrapping past `$FFFF`."
  @spec load(t(), 0..0xFFFF, binary()) :: t()
  def load(%__MODULE__{mode: :flat} = bus, address, contents)
      when address in 0x0000..0xFFFF and is_binary(contents) and
             address + byte_size(contents) <= 0x10000 do
    contents
    |> :binary.bin_to_list()
    |> Enum.with_index(address)
    |> Enum.reduce(bus, fn {value, offset}, bus -> load_byte(bus, offset, value) end)
  end

  defp load_byte(bus, 0xFF04, value), do: %{bus | divider: value <<< 8}
  defp load_byte(bus, 0xFF05, value), do: %{bus | tima: value}
  defp load_byte(bus, 0xFF06, value), do: %{bus | tma: value}
  defp load_byte(bus, 0xFF07, value), do: %{bus | tac: value &&& 0x07}
  defp load_byte(bus, 0xFF0F, value), do: %{bus | interrupt_flags: value &&& 0x1F}
  defp load_byte(bus, 0xFFFF, value), do: %{bus | ie: value}

  defp load_byte(%__MODULE__{memory: memory} = bus, address, value),
    do: %{bus | memory: :array.set(address, value, memory)}

  @doc "Reads one CPU-visible byte."
  @spec read(t(), 0..0xFFFF) :: byte()
  def read(%__MODULE__{} = bus, 0xFF00), do: joyp_value(bus)
  def read(%__MODULE__{serial_data: value}, 0xFF01), do: value

  def read(%__MODULE__{control: control, serial_control: value}, 0xFF02)
      when (control &&& @cgb) == 0,
      do: 0x7E ||| (value &&& 0x81)

  def read(%__MODULE__{serial_control: value}, 0xFF02), do: 0x7C ||| (value &&& 0x83)
  def read(%__MODULE__{divider: divider}, 0xFF04), do: divider >>> 8
  def read(%__MODULE__{tima: tima}, 0xFF05), do: tima
  def read(%__MODULE__{tma: tma}, 0xFF06), do: tma
  def read(%__MODULE__{tac: tac}, 0xFF07), do: 0xF8 ||| tac
  def read(%__MODULE__{interrupt_flags: flags}, 0xFF0F), do: 0xE0 ||| flags

  def read(%__MODULE__{mode: :mapped, apu: apu}, address) when address in 0xFF10..0xFF3F,
    do: apu |> APU.flush() |> APU.read(address)

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, address) when address in 0xFF40..0xFF45,
    do: PPU.read(ppu, address)

  def read(%__MODULE__{oam_dma: nil, control: control}, 0xFF46)
      when (control &&& @cgb) != 0,
      do: 0x00

  def read(%__MODULE__{oam_dma: nil}, 0xFF46), do: 0xFF
  def read(%__MODULE__{oam_dma: source}, 0xFF46), do: source

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, address) when address in 0xFF47..0xFF4B,
    do: PPU.read(ppu, address)

  def read(%__MODULE__{control: control}, 0xFF4D) when (control &&& @cgb) == 0, do: 0xFF

  def read(%__MODULE__{control: control}, 0xFF4D) do
    0x7E ||| if((control &&& @double_speed) != 0, do: 0x80, else: 0) |||
      if((control &&& @prepare_speed) != 0, do: 0x01, else: 0)
  end

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, 0xFF4F), do: PPU.read(ppu, 0xFF4F)
  def read(%__MODULE__{control: control}, 0xFF4F) when (control &&& @cgb) == 0, do: 0xFF
  def read(%__MODULE__{}, 0xFF4F), do: 0xFE
  def read(%__MODULE__{boot_disable: value}, 0xFF50), do: value

  def read(%__MODULE__{control: control}, address)
      when address in 0xFF51..0xFF55 and (control &&& @cgb) == 0,
      do: 0xFF

  def read(%__MODULE__{}, address) when address in 0xFF51..0xFF54, do: 0xFF
  def read(%__MODULE__{hdma: hdma}, 0xFF55), do: elem(hdma, 4)

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, address) when address in 0xFF68..0xFF6B,
    do: PPU.read(ppu, address)

  def read(%__MODULE__{control: control}, 0xFF70) when (control &&& @cgb) == 0, do: 0xFF
  def read(%__MODULE__{svbk: bank}, 0xFF70), do: 0xF8 ||| bank
  def read(%__MODULE__{ie: ie}, 0xFFFF), do: ie

  # Boot-disabled cartridge fetches are the normal runtime hot path.
  def read(%__MODULE__{mode: :mapped, boot_enabled: false, cartridge: cartridge}, address)
      when address in 0x0000..0x7FFF,
      do: Cartridge.read(cartridge, address)

  def read(
        %__MODULE__{mode: :mapped, boot_enabled: true, boot_rom: boot_rom} = bus,
        address
      )
      when address in 0x0000..0x00FF do
    if address < byte_size(boot_rom),
      do: :binary.at(boot_rom, address),
      else: Cartridge.read(bus.cartridge, address)
  end

  def read(
        %__MODULE__{
          mode: :mapped,
          boot_enabled: true,
          boot_rom: boot_rom,
          control: control
        } = bus,
        address
      )
      when address in 0x0200..0x08FF and (control &&& @cgb) != 0 do
    if address < byte_size(boot_rom),
      do: :binary.at(boot_rom, address),
      else: Cartridge.read(bus.cartridge, address)
  end

  def read(%__MODULE__{mode: :mapped, cartridge: cartridge}, address)
      when address in 0x0000..0x7FFF,
      do: Cartridge.read(cartridge, address)

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, address) when address in 0x8000..0x9FFF,
    do: PPU.read(ppu, address)

  def read(%__MODULE__{mode: :mapped, cartridge: cartridge}, address)
      when address in 0xA000..0xBFFF,
      do: Cartridge.read(cartridge, address)

  def read(%__MODULE__{mode: :mapped, wram: wram}, address) when address in 0xC000..0xCFFF,
    do: paged_byte(wram, address - 0xC000)

  def read(%__MODULE__{mode: :mapped, wram: wram} = bus, address)
      when address in 0xD000..0xDFFF,
      do: paged_byte(wram, selected_wram_bank(bus) * 0x1000 + address - 0xD000)

  def read(%__MODULE__{mode: :mapped} = bus, address) when address in 0xE000..0xFDFF,
    do: read(bus, address - 0x2000)

  def read(%__MODULE__{mode: :mapped, ppu: ppu}, address) when address in 0xFE00..0xFE9F,
    do: PPU.read(ppu, address)

  def read(%__MODULE__{mode: :mapped}, address) when address in 0xFEA0..0xFEFF, do: 0xFF

  def read(%__MODULE__{mode: :mapped, hram: hram}, address) when address in 0xFF80..0xFFFE,
    do: :binary.at(hram, address - 0xFF80)

  def read(%__MODULE__{mode: :mapped}, address) when address in 0xFF00..0xFF7F, do: 0xFF

  def read(%__MODULE__{mode: :flat, memory: memory}, address)
      when address in 0x0000..0xFFFF,
      do: :array.get(address, memory)

  @doc "Writes one CPU-visible byte."
  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{} = bus, 0xFF00, value), do: select_joypad(bus, value)
  def write(%__MODULE__{} = bus, 0xFF01, value), do: %{bus | serial_data: value}
  def write(%__MODULE__{} = bus, 0xFF02, value), do: start_serial(bus, value)
  def write(%__MODULE__{} = bus, 0xFF04, _value), do: reset_divider(bus)
  def write(%__MODULE__{} = bus, 0xFF05, value), do: %{bus | tima: value, timer_reload: 0}
  def write(%__MODULE__{} = bus, 0xFF06, value), do: %{bus | tma: value}

  def write(%__MODULE__{} = bus, 0xFF07, value) do
    old_input = timer_input(bus.divider, bus.tac)
    bus = %{bus | tac: value &&& 0x07}
    timer_control_edge(bus, old_input, timer_input(bus.divider, bus.tac))
  end

  def write(%__MODULE__{} = bus, 0xFF0F, value),
    do: %{bus | interrupt_flags: value &&& 0x1F}

  def write(%__MODULE__{mode: :mapped, apu: apu} = bus, address, value)
      when address in 0xFF10..0xFF3F,
      do: %{bus | apu: apu |> APU.flush() |> APU.write(address, value)}

  def write(%__MODULE__{mode: :mapped} = bus, address, value) when address in 0xFF40..0xFF45,
    do: write_ppu(bus, address, value)

  def write(%__MODULE__{} = bus, 0xFF46, value), do: %{bus | oam_dma: value}

  def write(%__MODULE__{mode: :mapped} = bus, address, value) when address in 0xFF47..0xFF4B,
    do: write_ppu(bus, address, value)

  def write(%__MODULE__{control: control} = bus, 0xFF4D, value)
      when (control &&& @cgb) != 0 do
    control =
      if (value &&& 0x01) != 0,
        do: control ||| @prepare_speed,
        else: control &&& bxor(0xFF, @prepare_speed)

    %{bus | control: control}
  end

  def write(%__MODULE__{} = bus, 0xFF4D, _value), do: bus

  def write(%__MODULE__{mode: :mapped} = bus, 0xFF4F, value),
    do: write_ppu(bus, 0xFF4F, value)

  def write(%__MODULE__{} = bus, 0xFF4F, _value), do: bus

  def write(%__MODULE__{boot_enabled: true} = bus, 0xFF50, value) when value != 0,
    do: %{bus | boot_enabled: false, boot_disable: value}

  def write(%__MODULE__{} = bus, 0xFF50, _value), do: bus

  def write(%__MODULE__{control: control} = bus, address, value)
      when address in 0xFF51..0xFF54 and (control &&& @cgb) != 0,
      do: put_hdma_register(bus, address, value)

  def write(%__MODULE__{control: control} = bus, 0xFF55, value)
      when (control &&& @cgb) != 0,
      do: request_hdma(bus, value)

  def write(%__MODULE__{} = bus, address, _value) when address in 0xFF51..0xFF55, do: bus

  def write(%__MODULE__{mode: :mapped} = bus, address, value) when address in 0xFF68..0xFF6B,
    do: write_ppu(bus, address, value)

  def write(%__MODULE__{control: control} = bus, 0xFF70, value)
      when (control &&& @cgb) != 0 do
    %{bus | svbk: value &&& 0x07}
  end

  def write(%__MODULE__{} = bus, 0xFF70, _value), do: bus
  def write(%__MODULE__{} = bus, 0xFFFF, value), do: %{bus | ie: value}

  def write(%__MODULE__{mode: :mapped, cartridge: cartridge} = bus, address, value)
      when address in 0x0000..0x7FFF or address in 0xA000..0xBFFF,
      do: %{bus | cartridge: Cartridge.write(cartridge, address, value)}

  def write(%__MODULE__{mode: :mapped} = bus, address, value)
      when address in 0x8000..0x9FFF,
      do: write_ppu(bus, address, value)

  def write(%__MODULE__{mode: :mapped, wram: wram} = bus, address, value)
      when address in 0xC000..0xCFFF,
      do: %{bus | wram: put_paged_byte(wram, address - 0xC000, value)}

  def write(%__MODULE__{mode: :mapped, wram: wram} = bus, address, value)
      when address in 0xD000..0xDFFF,
      do: %{
        bus
        | wram:
            put_paged_byte(
              wram,
              selected_wram_bank(bus) * 0x1000 + address - 0xD000,
              value
            )
      }

  def write(%__MODULE__{mode: :mapped} = bus, address, value)
      when address in 0xE000..0xFDFF,
      do: write(bus, address - 0x2000, value)

  def write(%__MODULE__{mode: :mapped} = bus, address, value)
      when address in 0xFE00..0xFE9F,
      do: write_ppu(bus, address, value)

  def write(%__MODULE__{mode: :mapped} = bus, address, _value)
      when address in 0xFEA0..0xFEFF,
      do: bus

  def write(%__MODULE__{mode: :mapped, hram: hram} = bus, address, value)
      when address in 0xFF80..0xFFFE,
      do: %{bus | hram: put_byte(hram, address - 0xFF80, value)}

  def write(%__MODULE__{mode: :mapped} = bus, address, _value)
      when address in 0xFF00..0xFF7F,
      do: bus

  def write(%__MODULE__{mode: :flat, memory: memory} = bus, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: %{bus | memory: :array.set(address, value, memory)}

  @doc false
  @spec read_cycle(t(), 0..0xFFFF) :: {byte(), t()}
  def read_cycle(%__MODULE__{mode: :mapped, apu: apu} = bus, address)
      when address in 0xFF10..0xFF3F do
    apu = APU.flush(apu)
    {APU.read(apu, address), tick(%{bus | apu: apu}, 4)}
  end

  def read_cycle(%__MODULE__{} = bus, address), do: {read(bus, address), tick(bus, 4)}

  @doc false
  @spec write_cycle(t(), 0..0xFFFF, byte()) :: t()
  def write_cycle(%__MODULE__{} = bus, address, value),
    do: bus |> write(address, value) |> tick(4)

  @doc false
  @spec idle(t(), non_neg_integer()) :: t()
  def idle(%__MODULE__{} = bus, m_cycles), do: tick(bus, m_cycles * 4)

  @doc "Reads a little-endian 16-bit value, wrapping the second address."
  @spec read16(t(), 0..0xFFFF) :: 0..0xFFFF
  def read16(%__MODULE__{} = bus, address) when address in 0x0000..0xFFFF do
    low = read(bus, address)
    high = read(bus, rem(address + 1, 0x10000))
    low + high * 0x100
  end

  @doc "Writes a little-endian 16-bit value, wrapping the second address."
  @spec write16(t(), 0..0xFFFF, 0..0xFFFF) :: t()
  def write16(%__MODULE__{} = bus, address, value)
      when address in 0x0000..0xFFFF and value in 0x0000..0xFFFF do
    bus
    |> write(address, rem(value, 0x100))
    |> write(rem(address + 1, 0x10000), div(value, 0x100))
  end

  @doc "Returns enabled, requested interrupt bits in hardware priority order."
  @spec pending_interrupts(t()) :: 0..0x1F
  def pending_interrupts(%__MODULE__{ie: ie, interrupt_flags: flags}), do: ie &&& flags &&& 0x1F

  @doc "Requests an interrupt. Atom clauses compile to literal masks."
  @spec request_interrupt(t(), interrupt()) :: t()
  def request_interrupt(bus, :vblank), do: request_interrupt_mask(bus, @interrupt_vblank)
  def request_interrupt(bus, :lcd_stat), do: request_interrupt_mask(bus, @interrupt_lcd_stat)
  def request_interrupt(bus, :timer), do: request_interrupt_mask(bus, @interrupt_timer)
  def request_interrupt(bus, :serial), do: request_interrupt_mask(bus, @interrupt_serial)
  def request_interrupt(bus, :joypad), do: request_interrupt_mask(bus, @interrupt_joypad)

  @doc false
  @spec acknowledge_interrupt(t(), 1 | 2 | 4 | 8 | 16) :: t()
  def acknowledge_interrupt(%__MODULE__{interrupt_flags: flags} = bus, mask),
    do: %{bus | interrupt_flags: flags &&& bxor(0x1F, mask)}

  @doc "Sets pressed buttons from an atom list or an eight-bit pressed mask."
  @spec set_buttons(t(), [atom()] | byte()) :: t()
  def set_buttons(%__MODULE__{} = bus, buttons) when is_list(buttons),
    do:
      set_buttons(
        bus,
        Enum.reduce(buttons, 0, fn button, mask -> mask ||| button_mask(button) end)
      )

  def set_buttons(%__MODULE__{} = bus, buttons) when buttons in 0x00..0xFF do
    before = joyp_value(bus) &&& 0x0F
    bus = %{bus | buttons: buttons}
    joypad_edge(bus, before, joyp_value(bus) &&& 0x0F)
  end

  @doc "Signals the joypad transition that can leave STOP and requests joypad IRQ."
  @spec signal_joypad_edge(t()) :: t()
  def signal_joypad_edge(%__MODULE__{control: control} = bus) do
    request_interrupt_mask(%{bus | control: control ||| @stop_wake}, @interrupt_joypad)
  end

  @doc false
  @spec take_stop_wake(t()) :: {boolean(), t()}
  def take_stop_wake(%__MODULE__{control: control} = bus) when (control &&& @stop_wake) != 0,
    do: {true, %{bus | control: control &&& bxor(0xFF, @stop_wake)}}

  def take_stop_wake(%__MODULE__{} = bus), do: {false, bus}

  @doc "Returns and clears bytes captured by internal-clock serial transfers."
  @spec take_serial_output(t()) :: {binary(), t()}
  def take_serial_output(%__MODULE__{serial_output: output} = bus),
    do: {output |> Enum.reverse() |> :erlang.list_to_binary(), %{bus | serial_output: []}}

  @doc "Returns and clears accumulated interleaved 44.1 kHz signed-16 stereo PCM."
  @spec take_audio_pcm(t()) :: {non_neg_integer(), binary(), t()}
  def take_audio_pcm(%__MODULE__{apu: nil} = bus), do: {0, <<>>, bus}

  def take_audio_pcm(%__MODULE__{apu: apu} = bus) do
    {sample_count, pcm, apu} = APU.take_samples(apu)
    {sample_count, pcm, %{bus | apu: apu}}
  end

  @doc "Returns and clears the pending OAM DMA source-page request."
  @spec take_oam_dma(t()) :: {byte() | nil, t()}
  def take_oam_dma(%__MODULE__{oam_dma: source} = bus), do: {source, %{bus | oam_dma: nil}}

  @doc "Returns and clears the pending CGB HDMA request."
  @spec take_hdma_request(t()) :: {hdma_request() | nil, t()}
  def take_hdma_request(%__MODULE__{hdma_request: request} = bus),
    do: {request, %{bus | hdma_request: nil}}

  @doc "Executes pending DMA work and returns the CPU stall in M-cycles."
  @spec run_dma(t(), boolean()) :: {t(), non_neg_integer()}
  def run_dma(bus, allow_hblank \\ true)

  def run_dma(%__MODULE__{mode: :flat} = bus, _allow_hblank), do: {bus, 0}

  def run_dma(%__MODULE__{} = bus, allow_hblank) when is_boolean(allow_hblank) do
    {bus, oam_cycles} = run_oam_dma(bus)
    {bus, general_cycles} = run_general_dma(bus)
    {bus, hblank_cycles} = run_hblank_dma(bus, allow_hblank, 0)
    {bus, oam_cycles + general_cycles + hblank_cycles}
  end

  @doc "Returns whether this bus models CGB hardware."
  @spec cgb?(t()) :: boolean()
  def cgb?(%__MODULE__{control: control}), do: (control &&& @cgb) != 0

  @doc "Returns the active CGB CPU speed."
  @spec double_speed?(t()) :: boolean()
  def double_speed?(%__MODULE__{control: control}), do: (control &&& @double_speed) != 0

  @doc "Applies a STOP boundary; the CGB speed-switch oscillator delay is not yet modeled."
  @spec stop(t()) :: {:stop | :speed_switch, t()}
  def stop(%__MODULE__{control: control} = bus)
      when (control &&& (@cgb ||| @prepare_speed)) == (@cgb ||| @prepare_speed) do
    clear = bxor(0xFF, @prepare_speed ||| @stop_wake)
    bus = reset_divider(bus)
    control = bxor(control, @double_speed) &&& clear
    {:speed_switch, %{bus | control: control}}
  end

  def stop(%__MODULE__{control: control} = bus),
    do: {:stop, %{bus | control: control &&& bxor(0xFF, @stop_wake)}}

  @doc "Advances timers by CPU T-cycles and mapped audio/video by base hardware dots."
  @spec tick(t(), non_neg_integer()) :: t()
  def tick(%__MODULE__{} = bus, 0), do: bus

  def tick(%__MODULE__{ppu: nil} = bus, clocks) when clocks > 0,
    do: tick_timers(bus, clocks)

  def tick(%__MODULE__{ppu: ppu, control: control, lcd_phase: phase} = bus, clocks)
      when clocks > 0 do
    {dots, phase} =
      if (control &&& @double_speed) == 0,
        do: {clocks, 0},
        else: {div(phase + clocks, 2), rem(phase + clocks, 2)}

    hblank_pending = pending_hblanks(bus, ppu, dots)
    bus = tick_timers(bus, clocks)
    apu = APU.defer_tick(bus.apu, dots)
    {ppu, signals} = PPU.tick(ppu, dots)

    apply_ppu_signals(
      %{bus | ppu: ppu, apu: apu, lcd_phase: phase, hblank_pending: hblank_pending},
      signals
    )
  end

  # OAM DMA is intentionally a single immutable-memory batch. The CPU is
  # stalled for the hardware's 160 M-cycles; in CGB double speed, tick/2 maps
  # those same CPU cycles to half as many LCD dots.
  defp run_oam_dma(%__MODULE__{oam_dma: nil} = bus), do: {bus, 0}

  defp run_oam_dma(%__MODULE__{oam_dma: page, ppu: ppu} = bus) do
    data = dma_bytes(bus, page <<< 8, 0xA0)
    bus = %{bus | oam_dma: nil, ppu: PPU.load_oam(ppu, 0, data)}
    {tick(bus, 160 * 4), 160}
  end

  defp run_general_dma(%__MODULE__{hdma_request: {:general, _, _, _}} = bus) do
    {bus, blocks} = transfer_general_blocks(bus, 0)
    m_cycles = blocks * hdma_block_mcycles(bus)
    {tick(bus, m_cycles * 4), m_cycles}
  end

  defp run_general_dma(%__MODULE__{} = bus), do: {bus, 0}

  defp transfer_general_blocks(
         %__MODULE__{hdma_request: {:general, source, destination, blocks}} = bus,
         count
       ) do
    bus = transfer_hdma_block(bus, :general, source, destination, blocks)
    transfer_general_blocks(bus, count + 1)
  end

  defp transfer_general_blocks(%__MODULE__{} = bus, count), do: {bus, count}

  defp run_hblank_dma(%__MODULE__{} = bus, false, m_cycles),
    do: {%{bus | hblank_pending: 0}, m_cycles}

  defp run_hblank_dma(
         %__MODULE__{
           hdma_request: {:hblank, source, destination, blocks},
           hblank_pending: pending
         } = bus,
         true,
         m_cycles
       )
       when pending > 0 do
    block_cycles = hdma_block_mcycles(bus)

    bus =
      bus
      |> Map.put(:hblank_pending, pending - 1)
      |> transfer_hdma_block(:hblank, source, destination, blocks)
      |> tick(block_cycles * 4)

    run_hblank_dma(bus, true, m_cycles + block_cycles)
  end

  defp run_hblank_dma(%__MODULE__{} = bus, true, m_cycles), do: {bus, m_cycles}

  defp transfer_hdma_block(bus, mode, source, destination, blocks) do
    data = dma_bytes(bus, source, 0x10)
    vram_offset = bus.ppu.vram_bank * 0x2000 + destination - 0x8000
    ppu = PPU.load_vram(bus.ppu, vram_offset, data)
    next_source = source + 0x10 &&& 0xFFFF
    next_destination = 0x8000 ||| (destination + 0x10 &&& 0x1FF0)
    next_blocks = blocks - 1

    hdma =
      bus.hdma
      |> put_elem(0, next_source >>> 8)
      |> put_elem(1, next_source &&& 0xF0)
      |> put_elem(2, next_destination >>> 8 &&& 0x1F)
      |> put_elem(3, next_destination &&& 0xF0)
      |> put_elem(4, if(next_blocks == 0, do: 0xFF, else: next_blocks - 1))

    request =
      if next_blocks == 0,
        do: nil,
        else: {mode, next_source, next_destination, next_blocks}

    %{bus | ppu: ppu, hdma: hdma, hdma_request: request}
  end

  defp dma_bytes(bus, address, size) do
    for offset <- 0..(size - 1), into: <<>> do
      <<read(bus, address + offset &&& 0xFFFF)>>
    end
  end

  # VRAM DMA consumes eight base-speed M-cycles per 16-byte block. It keeps
  # that wall-clock duration in double speed, where the CPU loses 16 fast
  # M-cycles while the PPU still advances 32 dots.
  defp hdma_block_mcycles(%__MODULE__{control: control})
       when (control &&& @double_speed) != 0,
       do: 16

  defp hdma_block_mcycles(%__MODULE__{}), do: 8

  defp pending_hblanks(
         %__MODULE__{
           hdma_request: {:hblank, _, _, blocks},
           hblank_pending: pending
         },
         ppu,
         dots
       ) do
    limit = blocks - pending
    pending + hblank_entries(ppu, dots, limit)
  end

  defp pending_hblanks(%__MODULE__{hblank_pending: pending}, _ppu, _dots), do: pending

  defp hblank_entries(_ppu, _dots, limit) when limit <= 0, do: 0

  defp hblank_entries(ppu, dots, limit) do
    if (PPU.read(ppu, 0xFF40) &&& 0x80) == 0,
      do: 0,
      else: count_hblank_entries(ppu.clock, dots, limit, 0)
  end

  defp count_hblank_entries(_clock, _dots, 0, count), do: count

  defp count_hblank_entries(clock, dots, limit, count) do
    line = div(clock, @dots_per_line)
    dot = rem(clock, @dots_per_line)

    distance =
      cond do
        line < @visible_lines and dot < @hblank_dot -> @hblank_dot - dot
        line < @visible_lines - 1 -> @dots_per_line - dot + @hblank_dot
        true -> @frame_dots - clock + @hblank_dot
      end

    if dots < distance do
      count
    else
      next_clock = rem(clock + distance, @frame_dots)
      count_hblank_entries(next_clock, dots - distance, limit - 1, count + 1)
    end
  end

  # Timer state stays in CPU T-cycles even while the PPU consumes base LCD
  # dots. Keeping this helper separate prevents timer recursion from advancing
  # the PPU more than once for the same ordered bus cycle.
  defp tick_timers(%__MODULE__{} = bus, 0), do: bus

  # The overwhelmingly common timer-off path avoids a per-clock loop.
  defp tick_timers(%__MODULE__{tac: tac, timer_reload: 0, divider: divider} = bus, clocks)
       when clocks > 0 and (tac &&& 0x04) == 0,
       do: %{bus | divider: divider + clocks &&& 0xFFFF}

  defp tick_timers(%__MODULE__{timer_reload: 0} = bus, clocks) when clocks > 0,
    do: tick_timer(bus, clocks)

  defp tick_timers(%__MODULE__{} = bus, clocks) when clocks > 0,
    do: tick_reload(bus, clocks)

  defp tick_timer(bus, 0), do: bus

  defp tick_timer(bus, clocks) do
    period = elem(@timer_periods, bus.tac &&& 0x03)
    until_edge = period - rem(bus.divider, period)

    if clocks < until_edge do
      %{bus | divider: bus.divider + clocks &&& 0xFFFF}
    else
      bus = %{bus | divider: bus.divider + until_edge &&& 0xFFFF}
      bus = increment_tima(bus)
      tick_timers(bus, clocks - until_edge)
    end
  end

  defp tick_reload(bus, 0), do: bus

  defp tick_reload(bus, clocks) do
    bus = advance_reload(bus)
    old_input = timer_input(bus.divider, bus.tac)
    bus = %{bus | divider: bus.divider + 1 &&& 0xFFFF}
    bus = timer_control_edge(bus, old_input, timer_input(bus.divider, bus.tac))
    tick_timers(bus, clocks - 1)
  end

  defp advance_reload(%__MODULE__{timer_reload: 0} = bus), do: bus

  defp advance_reload(%__MODULE__{timer_reload: 1, tma: tma} = bus) do
    request_interrupt_mask(%{bus | tima: tma, timer_reload: 0}, @interrupt_timer)
  end

  defp advance_reload(%__MODULE__{timer_reload: reload} = bus),
    do: %{bus | timer_reload: reload - 1}

  defp reset_divider(bus) do
    old_input = timer_input(bus.divider, bus.tac)
    apu = reset_apu_divider(bus.apu, apu_divider_input(bus.divider, bus.control) == 1)
    bus = %{bus | divider: 0, apu: apu}
    timer_control_edge(bus, old_input, timer_input(0, bus.tac))
  end

  defp reset_apu_divider(nil, _falling_edge?), do: nil

  defp reset_apu_divider(apu, falling_edge?),
    do: apu |> APU.flush() |> APU.reset_divider(falling_edge?)

  defp apu_divider_input(divider, control) when (control &&& @double_speed) == 0,
    do: divider >>> 12 &&& 1

  defp apu_divider_input(divider, _control), do: divider >>> 13 &&& 1

  defp timer_control_edge(bus, 1, 0), do: increment_tima(bus)
  defp timer_control_edge(bus, _old, _new), do: bus

  defp increment_tima(%__MODULE__{timer_reload: reload} = bus) when reload != 0, do: bus
  defp increment_tima(%__MODULE__{tima: 0xFF} = bus), do: %{bus | tima: 0, timer_reload: 4}
  defp increment_tima(%__MODULE__{tima: tima} = bus), do: %{bus | tima: tima + 1}

  defp request_interrupt_mask(%__MODULE__{interrupt_flags: flags} = bus, mask),
    do: %{bus | interrupt_flags: flags ||| mask}

  defp write_ppu(%__MODULE__{ppu: ppu} = bus, address, value) do
    {ppu, signals} = PPU.write(ppu, address, value)
    apply_ppu_signals(%{bus | ppu: ppu}, signals)
  end

  defp apply_ppu_signals(bus, []), do: bus

  defp apply_ppu_signals(bus, [:vblank | signals]),
    do: apply_ppu_signals(request_interrupt_mask(bus, @interrupt_vblank), signals)

  defp apply_ppu_signals(bus, [:lcd_stat | signals]),
    do: apply_ppu_signals(request_interrupt_mask(bus, @interrupt_lcd_stat), signals)

  defp apply_ppu_signals(bus, [{:frame, _number, _frame} | signals]),
    do: apply_ppu_signals(bus, signals)

  defp select_joypad(bus, value) do
    before = joyp_value(bus) &&& 0x0F
    bus = %{bus | joyp_select: value &&& 0x30}
    joypad_edge(bus, before, joyp_value(bus) &&& 0x0F)
  end

  defp joypad_edge(bus, before, after_value) do
    if (before &&& bxor(after_value, 0x0F)) != 0,
      do: signal_joypad_edge(bus),
      else: bus
  end

  defp joyp_value(%__MODULE__{joyp_select: select, buttons: buttons}) do
    directions = buttons &&& 0x0F
    actions = buttons >>> 4
    low = 0x0F
    low = if (select &&& 0x10) == 0, do: low &&& bxor(directions, 0x0F), else: low
    low = if (select &&& 0x20) == 0, do: low &&& bxor(actions, 0x0F), else: low
    0xC0 ||| select ||| low
  end

  defp button_mask(:right), do: 0x01
  defp button_mask(:left), do: 0x02
  defp button_mask(:up), do: 0x04
  defp button_mask(:down), do: 0x08
  defp button_mask(:a), do: 0x10
  defp button_mask(:b), do: 0x20
  defp button_mask(:select), do: 0x40
  defp button_mask(:start), do: 0x80

  defp start_serial(bus, value) do
    mask = if cgb?(bus), do: 0x83, else: 0x81
    control = value &&& mask
    bus = %{bus | serial_control: control}

    if (control &&& 0x81) == 0x81 do
      bus
      |> Map.put(:serial_data, 0xFF)
      |> Map.put(:serial_control, control &&& 0x03)
      |> Map.put(:serial_output, [bus.serial_data | bus.serial_output])
      |> request_interrupt_mask(@interrupt_serial)
    else
      bus
    end
  end

  defp put_hdma_register(%__MODULE__{hdma_request: {:hblank, _, _, _}} = bus, _address, _value),
    do: bus

  defp put_hdma_register(%__MODULE__{hdma: hdma} = bus, address, value) do
    index = address - 0xFF51

    value =
      case index do
        1 -> value &&& 0xF0
        2 -> value &&& 0x1F
        3 -> value &&& 0xF0
        _ -> value
      end

    %{bus | hdma: put_elem(hdma, index, value)}
  end

  defp request_hdma(
         %__MODULE__{hdma_request: {:hblank, _, _, blocks}, hdma: hdma} = bus,
         value
       )
       when (value &&& 0x80) == 0 do
    status = 0x80 ||| blocks - 1
    %{bus | hdma: put_elem(hdma, 4, status), hdma_request: nil, hblank_pending: 0}
  end

  defp request_hdma(%__MODULE__{hdma_request: {:hblank, _, _, _}} = bus, _value), do: bus

  defp request_hdma(%__MODULE__{hdma: hdma} = bus, value) do
    source = elem(hdma, 0) <<< 8 ||| elem(hdma, 1)
    destination = 0x8000 ||| elem(hdma, 2) <<< 8 ||| elem(hdma, 3)
    requested_mode = if (value &&& 0x80) == 0, do: :general, else: :hblank
    lcd_enabled = lcd_enabled?(bus.ppu)
    mode = if requested_mode == :hblank and lcd_enabled, do: :hblank, else: :general
    blocks = (value &&& 0x7F) + 1
    status = blocks - 1

    %{
      bus
      | hdma: put_elem(hdma, 4, status),
        hdma_request: {mode, source, destination, blocks},
        hblank_pending: 0
    }
  end

  defp selected_wram_bank(%__MODULE__{control: control}) when (control &&& @cgb) == 0, do: 1
  defp selected_wram_bank(%__MODULE__{svbk: 0}), do: 1
  defp selected_wram_bank(%__MODULE__{svbk: bank}), do: bank

  defp lcd_enabled?(nil), do: false
  defp lcd_enabled?(ppu), do: (PPU.read(ppu, 0xFF40) &&& 0x80) != 0

  defp cartridge_model(%{header: %{cgb_mode: :dmg_only}}), do: :dmg
  defp cartridge_model(%{header: %{}}), do: :cgb

  defp paged_byte(pages, offset),
    do: :binary.at(elem(pages, offset >>> 8), offset &&& 0xFF)

  defp put_paged_byte(pages, offset, value) do
    page_index = offset >>> 8
    page = elem(pages, page_index)
    put_elem(pages, page_index, put_byte(page, offset &&& 0xFF, value))
  end

  defp put_byte(binary, offset, value) do
    <<prefix::binary-size(^offset), _old, suffix::binary>> = binary
    prefix <> <<value &&& 0xFF>> <> suffix
  end

  defp timer_input(_divider, tac) when (tac &&& 0x04) == 0, do: 0
  defp timer_input(divider, tac) when (tac &&& 0x03) == 0, do: divider >>> 9 &&& 1
  defp timer_input(divider, tac) when (tac &&& 0x03) == 1, do: divider >>> 3 &&& 1
  defp timer_input(divider, tac) when (tac &&& 0x03) == 2, do: divider >>> 5 &&& 1
  defp timer_input(divider, _tac), do: divider >>> 7 &&& 1
end
