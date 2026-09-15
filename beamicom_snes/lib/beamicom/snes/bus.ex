defmodule Beamicom.SNES.Bus do
  @moduledoc """
  Initial SNES CPU bus with master-clock-priced accesses.

  Implemented regions are 128 KiB S-WRAM and its low-bank mirrors, cartridge
  ROM, controller ports, open-bus MMIO, and MEMSEL (`$420D`).
  """

  import Bitwise
  alias Beamicom.SNES.{APU, Cartridge, Cx4, PPU, Timing}

  @wram_size 128 * 1024
  @dma_channel %{
    dmap: 0,
    bbad: 0,
    a_addr: 0,
    a_bank: 0,
    size: 0,
    indirect_bank: 0,
    table_addr: 0,
    line_counter: 0,
    indirect_addr: 0,
    hdma_active?: false,
    hdma_do_transfer?: false
  }

  @enforce_keys [:cartridge, :wram, :sram, :timing, :ppu, :apu]
  defstruct @enforce_keys ++
              [
                fast_rom?: false,
                open_bus: 0,
                nmi_enable?: false,
                nmi_flag?: false,
                nmi_pending?: false,
                irq_mode: :off,
                irq_flag?: false,
                htime: 0x1FF,
                vtime: 0x1FF,
                multiplicand: 0,
                dividend: 0,
                quotient: 0,
                product_remainder: 0,
                wmadd: 0,
                joypad: %{
                  buttons: {0, 0},
                  shift: {0, 0},
                  latch?: false,
                  auto?: false,
                  results: {0, 0, 0, 0},
                  busy_from: 0,
                  busy_until: 0
                },
                dma_channels: nil,
                hdma_enable: 0,
                apu_pending_clocks: 0,
                cpu_pending_clocks: 0,
                coprocessor: nil
              ]

  @type t :: %__MODULE__{}

  @spec new(Cartridge.t(), keyword()) :: t()
  def new(%Cartridge{} = cartridge, opts \\ []) do
    region = Keyword.get(opts, :region, cartridge.header.region)
    sram_size = cartridge.header.declared_ram_size || 0

    timing = Timing.new(region: region)

    %__MODULE__{
      cartridge: cartridge,
      wram: :array.new(@wram_size, default: 0, fixed: true),
      sram: :array.new(sram_size, default: 0xFF, fixed: true),
      timing: timing,
      ppu: PPU.new(),
      apu: APU.new(native_ipl: true),
      coprocessor: if(Cx4.cartridge?(cartridge), do: Cx4.new()),
      dma_channels: List.duplicate(@dma_channel, 8) |> List.to_tuple()
    }
  end

  @doc "Pure read used for reset vectors and inspection; it does not advance time."
  @spec peek(t(), non_neg_integer()) :: byte()
  def peek(%__MODULE__{} = bus, address) do
    address = address &&& 0xFFFFFF

    case region(bus, address) do
      {:wram, offset} ->
        :array.get(offset, bus.wram)

      {:sram, offset} ->
        :array.get(offset, bus.sram)

      {:cx4, _offset} ->
        Cx4.read(bus.coprocessor, address)

      :rom ->
        Cartridge.read_or(bus.cartridge, address, bus.open_bus)

      {:apu_port, port} ->
        APU.cpu_read(bus.apu, port)

      {:wram_port, 0x2180} ->
        :array.get(bus.wmadd, bus.wram)

      {:joy_serial, port} ->
        joy_serial_value(bus, port)

      {:dma, channel, register} ->
        dma_register(elem(bus.dma_channels, channel), register)

      :memsel ->
        if(bus.fast_rom?, do: 1, else: 0)

      _other ->
        bus.open_bus
    end
  end

  @doc "Read a byte and return `{value, updated_bus, master_clocks}`."
  @spec read(t(), non_neg_integer()) :: {byte(), t(), pos_integer()}
  def read(%__MODULE__{} = bus, address) do
    address = address &&& 0xFFFFFF
    mapped = region(bus, address)
    clocks = access_clocks(bus, address, mapped)
    {value, bus} = read_region(bus, mapped, address)
    bus = bus |> Map.put(:open_bus, value) |> advance(clocks)
    {value, bus, clocks}
  end

  @doc "Write a byte and return `{updated_bus, master_clocks}`."
  @spec write(t(), non_neg_integer(), byte()) :: {t(), pos_integer()}
  def write(%__MODULE__{} = bus, address, value) when is_integer(value) do
    address = address &&& 0xFFFFFF
    value = value &&& 0xFF
    mapped = region(bus, address)
    clocks = access_clocks(bus, address, mapped)

    bus =
      case mapped do
        {:wram, offset} ->
          %{bus | wram: :array.set(offset, value, bus.wram)}

        {:sram, offset} ->
          %{bus | sram: :array.set(offset, value, bus.sram)}

        {:cx4, _offset} ->
          %{bus | coprocessor: Cx4.write(bus.coprocessor, address, value, bus.cartridge)}

        {:ppu, register} ->
          write_ppu(bus, register, value)

        {:apu_port, port} ->
          bus = flush_apu(bus)
          %{bus | apu: APU.cpu_write(bus.apu, port, value)}

        {:wram_port, register} ->
          write_wram_port(bus, register, value)

        {:joy_serial, 0} ->
          write_joy_latch(bus, value)

        {:dma, channel, register} ->
          write_dma_register(bus, channel, register, value)

        :memsel ->
          %{bus | fast_rom?: (value &&& 1) != 0}

        {:cpu_io, register} ->
          write_cpu_io(bus, register, value)

        _other ->
          bus
      end

    {%{bus | open_bus: value} |> advance(clocks), clocks}
  end

  @doc "Advance one or more internal CPU cycles (six master clocks each)."
  @spec idle(t(), pos_integer()) :: {t(), pos_integer()}
  def idle(%__MODULE__{} = bus, cycles \\ 1) when is_integer(cycles) and cycles > 0 do
    clocks = cycles * 6
    {advance(bus, clocks), clocks}
  end

  @doc false
  def cpu_read(%__MODULE__{} = bus, address) do
    address = address &&& 0xFFFFFF
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      bank in 0x7E..0x7F ->
        cpu_read_wram(bus, address - 0x7E0000)

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset < 0x2000 ->
        cpu_read_wram(bus, offset)

      cx4_address?(bus, address) ->
        cpu_read_cx4(bus, address)

      offset < 0x8000 and sram_address?(bus, bank, offset) ->
        {:ok, sram_offset} = Cartridge.address_to_sram_offset(bus.cartridge, address)
        value = :array.get(sram_offset, bus.sram)
        {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + 8}, 8}

      offset >= 0x8000 or bank in 0x40..0x6F or bank in 0xC0..0xEF ->
        cpu_read_rom(bus, address)

      bank in 0x40..0x7D or bank in 0xC0..0xFF or offset >= 0x6000 ->
        cpu_read_rom(bus, address)

      true ->
        cpu_read_mapped(bus, address)
    end
  end

  @doc false
  def cpu_write(%__MODULE__{} = bus, address, value) when is_integer(value) do
    address = address &&& 0xFFFFFF
    value = value &&& 0xFF
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      bank in 0x7E..0x7F ->
        cpu_write_wram(bus, address - 0x7E0000, value)

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset < 0x2000 ->
        cpu_write_wram(bus, offset, value)

      cx4_address?(bus, address) ->
        cpu_write_cx4(bus, address, value)

      offset < 0x8000 and sram_address?(bus, bank, offset) ->
        {:ok, sram_offset} = Cartridge.address_to_sram_offset(bus.cartridge, address)

        bus = %{
          bus
          | sram: :array.set(sram_offset, value, bus.sram),
            open_bus: value,
            cpu_pending_clocks: bus.cpu_pending_clocks + 8
        }

        {bus, 8}

      offset >= 0x8000 or bank in 0x40..0x6F or bank in 0xC0..0xEF ->
        clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8
        {%{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}

      bank in 0x40..0x7D or bank in 0xC0..0xFF or offset >= 0x6000 ->
        clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8
        {%{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}

      true ->
        cpu_write_mapped(bus, address, value)
    end
  end

  defp cpu_read_wram(bus, offset) do
    value = :array.get(offset, bus.wram)
    {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + 8}, 8}
  end

  defp cpu_read_rom(%{cartridge: %{layout: :lorom, rom: rom, size: size}} = bus, address)
       when (address &&& 0xFFFF) >= 0x8000 or (address >>> 16) in 0x40..0x6F or
              (address >>> 16) in 0xC0..0xEF do
    clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8
    raw_offset = (address >>> 16 &&& 0x7F) <<< 15 ||| (address &&& 0x7FFF)
    offset = if raw_offset < size, do: raw_offset, else: Cartridge.mirror_offset(raw_offset, size)
    value = :binary.at(rom, offset)

    {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}
  end

  defp cpu_read_rom(bus, address) do
    clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8

    value = Cartridge.read_or(bus.cartridge, address, bus.open_bus)

    {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}
  end

  defp cpu_read_cx4(bus, address) do
    value = Cx4.read(bus.coprocessor, address)
    {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + 8}, 8}
  end

  defp cpu_write_cx4(bus, address, value) do
    coprocessor = Cx4.write(bus.coprocessor, address, value, bus.cartridge)

    {%{
       bus
       | coprocessor: coprocessor,
         open_bus: value,
         cpu_pending_clocks: bus.cpu_pending_clocks + 8
     }, 8}
  end

  defp cpu_read_mapped(bus, address) do
    mapped = region(bus, address)
    clocks = access_clocks(bus, address, mapped)
    bus = sync_before_cpu_io(bus, mapped)
    {value, bus} = read_region(bus, mapped, address)
    {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}
  end

  defp cpu_write_wram(bus, offset, value) do
    bus = %{
      bus
      | wram: :array.set(offset, value, bus.wram),
        open_bus: value,
        cpu_pending_clocks: bus.cpu_pending_clocks + 8
    }

    {bus, 8}
  end

  defp cpu_write_mapped(bus, address, value) do
    mapped = region(bus, address)
    clocks = access_clocks(bus, address, mapped)
    bus = sync_before_cpu_io(bus, mapped)

    bus =
      case mapped do
        {:ppu, register} ->
          write_ppu(bus, register, value)

        {:apu_port, port} ->
          bus = flush_apu(bus)
          %{bus | apu: APU.cpu_write(bus.apu, port, value)}

        {:wram_port, register} ->
          write_wram_port(bus, register, value)

        {:joy_serial, 0} ->
          write_joy_latch(bus, value)

        {:dma, channel, register} ->
          write_dma_register(bus, channel, register, value)

        :memsel ->
          %{bus | fast_rom?: (value &&& 1) != 0}

        {:cpu_io, register} ->
          write_cpu_io(bus, register, value)

        _other ->
          bus
      end

    {%{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}
  end

  @doc false
  def cpu_idle(%__MODULE__{} = bus, cycles \\ 1) when is_integer(cycles) and cycles > 0 do
    clocks = cycles * 6
    {%{bus | cpu_pending_clocks: bus.cpu_pending_clocks + clocks}, clocks}
  end

  @doc false
  def flush_cpu_timing(%__MODULE__{cpu_pending_clocks: 0} = bus), do: bus

  def flush_cpu_timing(%__MODULE__{} = bus) do
    clocks = bus.cpu_pending_clocks

    advance(%{bus | cpu_pending_clocks: 0}, clocks)
  end

  @doc false
  def cpu_master_clocks(%__MODULE__{} = bus),
    do: bus.timing.master_clocks + bus.cpu_pending_clocks

  @doc false
  def flush_cpu_events(%__MODULE__{cpu_pending_clocks: 0} = bus), do: bus

  def flush_cpu_events(%__MODULE__{} = bus) do
    line_remaining = Timing.line_clocks(bus.timing) - bus.timing.hclock

    if bus.cpu_pending_clocks >= line_remaining or pending_h_irq?(bus) do
      flush_cpu_timing(bus)
    else
      bus
    end
  end

  @doc "Consumes the edge-latched NMI request presented to the CPU."
  @spec take_nmi(t()) :: {boolean(), t()}
  def take_nmi(%__MODULE__{nmi_pending?: false} = bus), do: {false, bus}
  def take_nmi(%__MODULE__{} = bus), do: {true, %{bus | nmi_pending?: false}}

  @spec irq_pending?(t()) :: boolean()
  def irq_pending?(%__MODULE__{irq_flag?: flag?}), do: flag?

  @doc "Drains the completed native RGB24 frame, if any."
  def take_frame(%__MODULE__{ppu: ppu} = bus) do
    {frame, ppu} = PPU.take_frame(ppu)
    {frame, %{bus | ppu: ppu}}
  end

  @doc "Drains nominal 32 kHz signed-16 little-endian stereo PCM."
  def take_audio_pcm(%__MODULE__{} = bus) do
    bus = flush_apu(bus)
    apu = bus.apu
    {frames, pcm, apu} = APU.take_pcm(apu)
    {frames, pcm, %{bus | apu: apu}}
  end

  @doc "Sets one standard controller's 16-bit SNES button report."
  @spec set_joypad(t(), 1 | 2, non_neg_integer()) :: t()
  def set_joypad(%__MODULE__{} = bus, port, report) when port in [1, 2] do
    buttons = put_elem(bus.joypad.buttons, port - 1, report &&& 0xFFFF)
    joypad = %{bus.joypad | buttons: buttons}
    joypad = if joypad.latch?, do: %{joypad | shift: buttons}, else: joypad
    %{bus | joypad: joypad}
  end

  @doc "Returns one standard controller's current 16-bit button report."
  @spec joypad_report(t(), 1 | 2) :: non_neg_integer()
  def joypad_report(%__MODULE__{} = bus, port) when port in [1, 2],
    do: elem(bus.joypad.buttons, port - 1)

  @doc "Advances an arbitrary number of master clocks through all native devices."
  @spec advance_master(t(), non_neg_integer()) :: t()
  def advance_master(%__MODULE__{} = bus, clocks)
      when is_integer(clocks) and clocks >= 0,
      do: advance(bus, clocks)

  @doc "Master clocks used by an access in the current MEMSEL state."
  @spec access_clocks(t(), non_neg_integer()) :: 6 | 8 | 12
  def access_clocks(%__MODULE__{} = bus, address) do
    address = address &&& 0xFFFFFF
    access_clocks(bus, address, region(bus, address))
  end

  defp access_clocks(bus, address, mapped) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      bank in 0x00..0x3F and offset in [0x4016, 0x4017] -> 12
      bank in 0x80..0xBF and offset in [0x4016, 0x4017] -> 12
      match?({:wram, _}, mapped) -> 8
      match?({:sram, _}, mapped) -> 8
      match?({:cx4, _}, mapped) -> 8
      mapped == :rom and bus.fast_rom? and address >= 0x800000 -> 6
      mapped == :rom -> 8
      true -> 6
    end
  end

  defp region(bus, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    sram_offset = Cartridge.address_to_sram_offset(bus.cartridge, address)

    cond do
      bank in [0x7E, 0x7F] ->
        {:wram, address - 0x7E0000}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset < 0x2000 ->
        {:wram, offset}

      cx4_address?(bus, address) ->
        {:cx4, offset - 0x6000}

      match?({:ok, _offset}, sram_offset) ->
        {:ok, offset} = sram_offset
        {:sram, offset}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x2100..0x213F ->
        {:ppu, offset}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x2140..0x217F ->
        {:apu_port, rem(offset - 0x2140, 4)}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x2180..0x2183 ->
        {:wram_port, offset}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset == 0x420D ->
        :memsel

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x4200..0x421F ->
        {:cpu_io, offset}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x4300..0x437F ->
        {:dma, div(offset - 0x4300, 0x10), rem(offset, 0x10)}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x2000..0x5FFF ->
        case offset do
          0x4016 -> {:joy_serial, 0}
          0x4017 -> {:joy_serial, 1}
          _other -> :mmio
        end

      true ->
        :rom
    end
  end

  defp read_region(bus, {:ppu, register}, _address) do
    {value, ppu} = PPU.read(bus.ppu, register, bus.open_bus)
    {value, %{bus | ppu: ppu}}
  end

  defp read_region(bus, {:apu_port, port}, _address),
    do:
      (
        bus = flush_apu(bus)
        {value, apu} = APU.sync_cpu_read(bus.apu, port)
        {value, %{bus | apu: apu}}
      )

  defp read_region(bus, {:wram, offset}, _address), do: {:array.get(offset, bus.wram), bus}

  defp read_region(bus, {:sram, offset}, _address), do: {:array.get(offset, bus.sram), bus}

  defp read_region(bus, {:cx4, _offset}, address), do: {Cx4.read(bus.coprocessor, address), bus}

  defp read_region(bus, {:wram_port, 0x2180}, _address) do
    value = :array.get(bus.wmadd, bus.wram)
    {value, %{bus | wmadd: bus.wmadd + 1 &&& 0x1FFFF}}
  end

  defp read_region(bus, {:joy_serial, port}, _address), do: read_joy_serial(bus, port)

  defp read_region(bus, :rom, address) do
    {Cartridge.read_or(bus.cartridge, address, bus.open_bus), bus}
  end

  defp read_region(bus, :memsel, _address), do: {if(bus.fast_rom?, do: 1, else: 0), bus}

  defp read_region(bus, {:dma, channel, register}, _address),
    do: {dma_register(elem(bus.dma_channels, channel), register), bus}

  defp read_region(bus, {:cpu_io, 0x4210}, _address) do
    value = (bus.open_bus &&& 0x70) ||| if(bus.nmi_flag?, do: 0x82, else: 0x02)
    {value, %{bus | nmi_flag?: false}}
  end

  defp read_region(bus, {:cpu_io, 0x4211}, _address) do
    value = (bus.open_bus &&& 0x7F) ||| if(bus.irq_flag?, do: 0x80, else: 0)
    {value, %{bus | irq_flag?: false}}
  end

  defp read_region(bus, {:cpu_io, 0x4212}, _address) do
    hblank? = bus.timing.hclock < 88 or bus.timing.hclock >= 1112
    value = if(Timing.vblank?(bus.timing), do: 0x80, else: 0)
    value = if(hblank?, do: value ||| 0x40, else: value)

    auto_read? =
      bus.timing.master_clocks >= bus.joypad.busy_from and
        bus.timing.master_clocks < bus.joypad.busy_until

    value = if(auto_read?, do: value ||| 0x01, else: value)
    {value, bus}
  end

  defp read_region(bus, {:cpu_io, register}, _address) when register in 0x4218..0x421F do
    index = div(register - 0x4218, 2)
    report = elem(bus.joypad.results, index)
    value = if(rem(register, 2) == 0, do: report &&& 0xFF, else: report >>> 8)
    {value, bus}
  end

  defp read_region(bus, {:cpu_io, register}, _address) when register in 0x4214..0x4217 do
    value =
      case register do
        0x4214 -> bus.quotient &&& 0xFF
        0x4215 -> bus.quotient >>> 8
        0x4216 -> bus.product_remainder &&& 0xFF
        0x4217 -> bus.product_remainder >>> 8
      end

    {value, bus}
  end

  defp read_region(bus, _region, address), do: {peek(bus, address), bus}

  defp sync_before_cpu_io(bus, {:ppu, _register}), do: flush_cpu_timing(bus)
  defp sync_before_cpu_io(bus, {:apu_port, _port}), do: flush_cpu_timing(bus)
  defp sync_before_cpu_io(bus, {:cpu_io, _register}), do: flush_cpu_timing(bus)
  defp sync_before_cpu_io(bus, {:joy_serial, _port}), do: flush_cpu_timing(bus)
  defp sync_before_cpu_io(bus, _mapped), do: bus

  defp pending_h_irq?(%{irq_mode: mode} = bus) when mode in [:h, :hv] do
    target = bus.htime * 4
    qualified? = mode == :h or bus.timing.vline == bus.vtime

    qualified? and target > bus.timing.hclock and
      target <= bus.timing.hclock + bus.cpu_pending_clocks
  end

  defp pending_h_irq?(_bus), do: false

  defp write_ppu(bus, register, value) do
    ppu = PPU.write(bus.ppu, register, value)

    timing =
      if register == 0x2133 do
        %{bus.timing | interlace?: ppu.interlace?, overscan?: ppu.overscan?}
      else
        bus.timing
      end

    %{bus | ppu: ppu, timing: timing}
  end

  defp write_wram_port(bus, 0x2180, value),
    do: %{
      bus
      | wram: :array.set(bus.wmadd, value, bus.wram),
        wmadd: bus.wmadd + 1 &&& 0x1FFFF
    }

  defp write_wram_port(bus, 0x2181, value), do: %{bus | wmadd: (bus.wmadd &&& 0x1FF00) ||| value}

  defp write_wram_port(bus, 0x2182, value),
    do: %{bus | wmadd: (bus.wmadd &&& 0x100FF) ||| value <<< 8}

  defp write_wram_port(bus, 0x2183, value),
    do: %{bus | wmadd: (bus.wmadd &&& 0x0FFFF) ||| (value &&& 1) <<< 16}

  defp write_cpu_io(bus, 0x4200, value) do
    nmi_enable? = (value &&& 0x80) != 0
    auto_joypad? = (value &&& 0x01) != 0

    irq_mode =
      case value >>> 4 &&& 0x03 do
        0 -> :off
        1 -> :h
        2 -> :v
        3 -> :hv
      end

    nmi_pending? =
      bus.nmi_pending? or
        (nmi_enable? and not bus.nmi_enable? and Timing.vblank?(bus.timing) and bus.nmi_flag?)

    %{
      bus
      | nmi_enable?: nmi_enable?,
        nmi_pending?: nmi_pending?,
        irq_mode: irq_mode,
        joypad: %{bus.joypad | auto?: auto_joypad?}
    }
  end

  defp write_cpu_io(bus, 0x4202, value), do: %{bus | multiplicand: value}

  defp write_cpu_io(bus, 0x4203, value),
    do: %{bus | product_remainder: bus.multiplicand * value}

  defp write_cpu_io(bus, 0x4204, value),
    do: %{bus | dividend: (bus.dividend &&& 0xFF00) ||| value}

  defp write_cpu_io(bus, 0x4205, value),
    do: %{bus | dividend: (bus.dividend &&& 0x00FF) ||| value <<< 8}

  defp write_cpu_io(bus, 0x4206, 0),
    do: %{bus | quotient: 0xFFFF, product_remainder: bus.dividend}

  defp write_cpu_io(bus, 0x4206, value),
    do: %{
      bus
      | quotient: div(bus.dividend, value),
        product_remainder: rem(bus.dividend, value)
    }

  defp write_cpu_io(bus, 0x4207, value), do: %{bus | htime: (bus.htime &&& 0x100) ||| value}

  defp write_cpu_io(bus, 0x4208, value),
    do: %{bus | htime: (bus.htime &&& 0x0FF) ||| (value &&& 1) <<< 8}

  defp write_cpu_io(bus, 0x4209, value), do: %{bus | vtime: (bus.vtime &&& 0x100) ||| value}

  defp write_cpu_io(bus, 0x420A, value),
    do: %{bus | vtime: (bus.vtime &&& 0x0FF) ||| (value &&& 1) <<< 8}

  defp write_cpu_io(bus, 0x420B, value), do: run_dma(bus, value)

  defp write_cpu_io(bus, 0x420C, value) do
    ppu =
      if value != 0 and not Timing.vblank?(bus.timing),
        do: PPU.enable_scanline_capture(bus.ppu, bus.timing.vline),
        else: bus.ppu

    %{bus | hdma_enable: value, ppu: ppu}
  end

  defp write_cpu_io(bus, 0x420D, value), do: %{bus | fast_rom?: (value &&& 1) != 0}
  defp write_cpu_io(bus, _register, _value), do: bus

  defp write_joy_latch(bus, value) do
    latch? = (value &&& 1) != 0

    if latch? do
      %{bus | joypad: %{bus.joypad | latch?: true, shift: bus.joypad.buttons}}
    else
      %{bus | joypad: %{bus.joypad | latch?: false}}
    end
  end

  defp read_joy_serial(bus, port) do
    value = joy_serial_value(bus, port)

    bus =
      if bus.joypad.latch? do
        bus
      else
        shift = elem(bus.joypad.shift, port)

        joypad = %{
          bus.joypad
          | shift: put_elem(bus.joypad.shift, port, (shift <<< 1 ||| 1) &&& 0xFFFF)
        }

        %{bus | joypad: joypad}
      end

    {value, bus}
  end

  defp joy_serial_value(bus, port) do
    report =
      if bus.joypad.latch?,
        do: elem(bus.joypad.buttons, port),
        else: elem(bus.joypad.shift, port)

    data = report >>> 15 &&& 1
    if port == 0, do: (bus.open_bus &&& 0xFC) ||| data, else: 0x1C ||| data
  end

  defp write_dma_register(bus, channel, register, value) do
    dma = elem(bus.dma_channels, channel)

    dma =
      case register do
        0x0 -> %{dma | dmap: value}
        0x1 -> %{dma | bbad: value}
        0x2 -> %{dma | a_addr: (dma.a_addr &&& 0xFF00) ||| value}
        0x3 -> %{dma | a_addr: (dma.a_addr &&& 0x00FF) ||| value <<< 8}
        0x4 -> %{dma | a_bank: value}
        0x5 -> %{dma | size: (dma.size &&& 0xFF00) ||| value}
        0x6 -> %{dma | size: (dma.size &&& 0x00FF) ||| value <<< 8}
        0x7 -> %{dma | indirect_bank: value}
        0x8 -> %{dma | table_addr: (dma.table_addr &&& 0xFF00) ||| value}
        0x9 -> %{dma | table_addr: (dma.table_addr &&& 0x00FF) ||| value <<< 8}
        0xA -> %{dma | line_counter: value}
        _ -> dma
      end

    %{bus | dma_channels: put_elem(bus.dma_channels, channel, dma)}
  end

  defp dma_register(dma, register) do
    case register do
      0x0 -> dma.dmap
      0x1 -> dma.bbad
      0x2 -> dma.a_addr &&& 0xFF
      0x3 -> dma.a_addr >>> 8
      0x4 -> dma.a_bank
      0x5 -> dma.size &&& 0xFF
      0x6 -> dma.size >>> 8
      0x7 -> dma.indirect_bank
      0x8 -> dma.table_addr &&& 0xFF
      0x9 -> dma.table_addr >>> 8
      0xA -> dma.line_counter
      _ -> 0
    end
  end

  defp run_dma(bus, mask) do
    Enum.reduce(0..7, bus, fn channel, bus ->
      if (mask &&& 1 <<< channel) != 0, do: run_dma_channel(bus, channel), else: bus
    end)
  end

  defp run_dma_channel(bus, channel) do
    dma = elem(bus.dma_channels, channel)
    count = if dma.size == 0, do: 0x10000, else: dma.size
    pattern = dma_pattern(dma.dmap &&& 0x07)
    direction = if (dma.dmap &&& 0x80) == 0, do: :a_to_b, else: :b_to_a
    fixed? = (dma.dmap &&& 0x08) != 0
    decrement? = (dma.dmap &&& 0x10) != 0

    {bus, final_addr} =
      Enum.reduce(0..(count - 1), {bus, dma.a_addr}, fn index, {bus, a_addr} ->
        a_bus = dma.a_bank <<< 16 ||| a_addr
        b_bus = 0x002100 + dma.bbad + elem(pattern, rem(index, tuple_size(pattern)))

        bus =
          case direction do
            :a_to_b -> raw_write(bus, b_bus, peek(bus, a_bus))
            :b_to_a -> raw_write(bus, a_bus, raw_read(bus, b_bus))
          end

        next_addr =
          cond do
            fixed? -> a_addr
            decrement? -> a_addr - 1 &&& 0xFFFF
            true -> a_addr + 1 &&& 0xFFFF
          end

        {bus, next_addr}
      end)

    dma = %{dma | a_addr: final_addr, size: 0}
    bus = %{bus | dma_channels: put_elem(bus.dma_channels, channel, dma)}
    advance(bus, count * 8 + 8)
  end

  defp dma_pattern(0), do: {0}
  defp dma_pattern(1), do: {0, 1}
  defp dma_pattern(2), do: {0, 0}
  defp dma_pattern(3), do: {0, 0, 1, 1}
  defp dma_pattern(4), do: {0, 1, 2, 3}
  defp dma_pattern(5), do: {0, 1, 0, 1}
  defp dma_pattern(6), do: {0, 0}
  defp dma_pattern(7), do: {0, 0, 1, 1}

  defp raw_read(bus, address) do
    case region(bus, address) do
      {:ppu, register} -> elem(PPU.read(bus.ppu, register, bus.open_bus), 0)
      {:apu_port, port} -> APU.cpu_read(bus.apu, port)
      _ -> peek(bus, address)
    end
  end

  defp raw_write(bus, address, value) do
    case region(bus, address) do
      {:wram, offset} ->
        %{bus | wram: :array.set(offset, value, bus.wram)}

      {:sram, offset} ->
        %{bus | sram: :array.set(offset, value, bus.sram)}

      {:cx4, _offset} ->
        %{bus | coprocessor: Cx4.write(bus.coprocessor, address, value, bus.cartridge)}

      {:ppu, register} ->
        write_ppu(bus, register, value)

      {:apu_port, port} ->
        %{bus | apu: APU.cpu_write(bus.apu, port, value)}

      {:wram_port, register} ->
        write_wram_port(bus, register, value)

      _ ->
        bus
    end
  end

  defp sram_address?(%{cartridge: %{header: %{declared_ram_size: size}}}, _bank, _offset)
       when size in [nil, 0],
       do: false

  defp sram_address?(%{cartridge: %{layout: :lorom}}, bank, offset),
    do: offset < 0x8000 and (bank in 0x70..0x7D or bank in 0xF0..0xFF)

  defp sram_address?(%{cartridge: %{layout: layout}}, bank, offset)
       when layout in [:hirom, :exhirom],
       do: offset in 0x6000..0x7FFF and (bank in 0x20..0x3F or bank in 0xA0..0xBF)

  defp cx4_address?(%{coprocessor: %Cx4{}}, address), do: Cx4.mapped?(address)
  defp cx4_address?(_bus, _address), do: false

  defp initialize_hdma(bus) do
    channels =
      0..7
      |> Enum.reduce(bus.dma_channels, fn channel, channels ->
        dma = elem(channels, channel)
        enabled? = (bus.hdma_enable &&& 1 <<< channel) != 0

        dma = %{
          dma
          | table_addr: dma.a_addr,
            line_counter: 0,
            indirect_addr: 0,
            hdma_active?: enabled?,
            hdma_do_transfer?: enabled?
        }

        put_elem(channels, channel, dma)
      end)

    %{bus | dma_channels: channels}
  end

  defp run_hdma_line(bus) do
    Enum.reduce(0..7, bus, fn channel, bus ->
      dma = elem(bus.dma_channels, channel)

      if (bus.hdma_enable &&& 1 <<< channel) != 0 and dma.hdma_active? do
        {bus, dma} = maybe_reload_hdma(bus, dma)

        {bus, dma} =
          if dma.hdma_active? and dma.hdma_do_transfer?,
            do: transfer_hdma(bus, dma),
            else: {bus, dma}

        dma =
          if dma.hdma_active? do
            counter = dma.line_counter - 1 &&& 0xFF
            %{dma | line_counter: counter, hdma_do_transfer?: (counter &&& 0x80) != 0}
          else
            dma
          end

        %{bus | dma_channels: put_elem(bus.dma_channels, channel, dma)}
      else
        bus
      end
    end)
  end

  defp maybe_reload_hdma(bus, %{line_counter: counter} = dma) when (counter &&& 0x7F) != 0,
    do: {bus, dma}

  defp maybe_reload_hdma(bus, dma) do
    descriptor = peek(bus, dma.a_bank <<< 16 ||| dma.table_addr)
    table_addr = dma.table_addr + 1 &&& 0xFFFF

    cond do
      descriptor == 0 ->
        {bus, %{dma | table_addr: table_addr, hdma_active?: false, hdma_do_transfer?: false}}

      (dma.dmap &&& 0x40) != 0 ->
        low = peek(bus, dma.a_bank <<< 16 ||| table_addr)
        high = peek(bus, dma.a_bank <<< 16 ||| (table_addr + 1 &&& 0xFFFF))

        {bus,
         %{
           dma
           | table_addr: table_addr + 2 &&& 0xFFFF,
             line_counter: descriptor,
             indirect_addr: low ||| high <<< 8,
             hdma_do_transfer?: true
         }}

      true ->
        {bus, %{dma | table_addr: table_addr, line_counter: descriptor, hdma_do_transfer?: true}}
    end
  end

  defp transfer_hdma(bus, dma) do
    pattern = dma_pattern(dma.dmap &&& 0x07)
    indirect? = (dma.dmap &&& 0x40) != 0

    {bus, source} =
      0..(tuple_size(pattern) - 1)
      |> Enum.reduce({bus, if(indirect?, do: dma.indirect_addr, else: dma.table_addr)}, fn index,
                                                                                           {bus,
                                                                                            source} ->
        bank = if indirect?, do: dma.indirect_bank, else: dma.a_bank
        value = peek(bus, bank <<< 16 ||| source)
        b_bus = 0x002100 + dma.bbad + elem(pattern, index)
        {raw_write(bus, b_bus, value), source + 1 &&& 0xFFFF}
      end)

    dma =
      if indirect?,
        do: %{dma | indirect_addr: source},
        else: %{dma | table_addr: source}

    {bus, dma}
  end

  defp advance(bus, 0), do: bus

  defp advance(bus, clocks) do
    line_remaining = Timing.line_clocks(bus.timing) - bus.timing.hclock
    span = min(clocks, line_remaining)
    before = bus.timing
    timing = Timing.advance(before, span)

    bus =
      %{bus | timing: timing, apu_pending_clocks: bus.apu_pending_clocks + span}
      |> maybe_h_irq(before, span)

    bus =
      if span == line_remaining do
        bus |> enter_scanline(before) |> maybe_line_irq()
      else
        bus
      end

    advance(bus, clocks - span)
  end

  defp flush_apu(%{apu_pending_clocks: 0} = bus), do: bus

  defp flush_apu(bus) do
    apu = APU.advance(bus.apu, bus.apu_pending_clocks, bus.timing.region)
    %{bus | apu: apu, apu_pending_clocks: 0}
  end

  defp maybe_h_irq(%{irq_mode: mode} = bus, before, span) when mode in [:h, :hv] do
    target = bus.htime * 4
    qualified? = mode == :h or before.vline == bus.vtime

    if qualified? and target > before.hclock and target <= before.hclock + span,
      do: %{bus | irq_flag?: true},
      else: bus
  end

  defp maybe_h_irq(bus, _before, _span), do: bus

  defp enter_scanline(bus, before) do
    line = bus.timing.vline

    bus =
      if line == 0 do
        bus = initialize_hdma(bus)
        %{bus | ppu: PPU.begin_frame(bus.ppu, bus.hdma_enable != 0)}
      else
        bus
      end

    bus = if line < 225 and bus.hdma_enable != 0, do: run_hdma_line(bus), else: bus
    ppu = bus.ppu |> PPU.capture_scanline(line) |> PPU.enter_scanline(line)
    entered_vblank? = not Timing.vblank?(before) and Timing.vblank?(bus.timing)

    if entered_vblank? do
      bus = %{bus | ppu: ppu, nmi_flag?: true, nmi_pending?: bus.nmi_pending? or bus.nmi_enable?}
      if bus.joypad.auto?, do: start_auto_joypad(bus), else: bus
    else
      %{bus | ppu: ppu}
    end
  end

  defp start_auto_joypad(bus) do
    {first, second} = bus.joypad.buttons
    busy_from = bus.timing.master_clocks + 128

    joypad = %{
      bus.joypad
      | results: {first, second, 0, 0},
        shift: {0xFFFF, 0xFFFF},
        busy_from: busy_from,
        busy_until: busy_from + 4224
    }

    %{bus | joypad: joypad}
  end

  defp maybe_line_irq(%{irq_mode: :v, timing: %{vline: line}, vtime: line} = bus),
    do: %{bus | irq_flag?: true}

  defp maybe_line_irq(%{irq_mode: :h, htime: 0} = bus), do: %{bus | irq_flag?: true}

  defp maybe_line_irq(%{irq_mode: :hv, htime: 0, timing: %{vline: line}, vtime: line} = bus),
    do: %{bus | irq_flag?: true}

  defp maybe_line_irq(bus), do: bus
end
