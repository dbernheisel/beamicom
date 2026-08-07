defmodule Beamicom.NES.Bus do
  @moduledoc """
  CPU-visible memory map: 2KB internal RAM (mirrored to $1FFF), PPU registers
  ($2000-$3FFF, mirrored every 8), OAM DMA ($4014), cartridge PRG-RAM
  ($6000-$7FFF), and mapper-banked PRG-ROM ($8000-$FFFF as four 8KB windows).

  Reads split in two: `peek/2` is a pure view for the instruction stream, zero
  page pointers, the stack, and vectors (never register space); `read/2` returns
  `{value, bus}` because PPU register reads mutate. `ppu` may be nil for headless
  CPU-only runs. Writes to $8000-$FFFF are cartridge mapper register writes,
  dispatched to `Beamicom.NES.Mapper`. Mapper-specific registers and uncommon
  routing flags live together in `mapper_state`; only mapper identity, PRG bank
  offsets, and IRQ projections remain top-level because CPU execution polls them.

  ## Sources
    * NESdev Wiki — CPU memory map: https://www.nesdev.org/wiki/CPU_memory_map
    * NESdev Wiki — OAM DMA ($4014): https://www.nesdev.org/wiki/DMA
  """

  import Bitwise
  alias Beamicom.NES.{Mapper, PPU}

  # Match APU's lazy-run threshold, but keep the per-instruction accumulator on
  # the smaller Bus state so the large APU struct is not rebuilt every step.
  @apu_flush_threshold 100

  @default_mapper_state %{
    submapper: 0,
    prg_ram_size: 0x2000,
    wram_source: :ram,
    wram_enabled: true,
    wram_writable: true,
    wram_bank: 0,
    prg_ram_windows: 0,
    shift: 0,
    shift_count: 0,
    ctrl: 0x0C,
    chr0: 0,
    chr1: 0,
    prg_reg: 0,
    bank_select: 0,
    regs: {0, 0, 0, 0, 0, 0, 0, 0},
    mmc6_ram_enabled: false,
    mmc6_read_mask: 0,
    mmc6_write_mask: 0,
    irq_latch: 0,
    irq_counter: 0,
    irq_reload: false,
    fme_cmd: 0,
    fme_count_on: false,
    prg_mode: 3,
    chr_mode: 3,
    m5_prg_regs: {0, 0x80, 0x81, 0x82, 0xFF},
    m5_protect1: 1,
    m5_protect2: 2,
    mul_a: 0,
    mul_b: 0,
    chr_regs: {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    chr_hi: 0
  }

  defstruct [
    :ram,
    :wram,
    :prg,
    ppu: nil,
    dma: false,
    pad1: %{buttons: 0, index: 0, strobe: false},
    pad2: %{buttons: 0, index: 0, strobe: false},
    mapper: 0,
    mapper_state: @default_mapper_state,
    # PRG as four 8KB window offsets ($8000/$A000/$C000/$E000).
    prg_banks: {0, 0x2000, 0, 0x2000},
    # IRQ line projections stay top-level because the CPU polls them every instruction.
    irq_enabled: false,
    irq_pending: false,
    apu: nil,
    apu_pending: 0
  ]

  def default_mapper_state, do: @default_mapper_state

  def new(%Beamicom.NES.Cart{} = cart, ppu \\ nil) do
    bus = %__MODULE__{
      ram: <<0::size(0x800 * 8)>>,
      wram: %{},
      prg: cart.prg_rom,
      ppu: ppu,
      mapper: cart.mapper,
      mapper_state: %{
        @default_mapper_state
        | submapper: cart.submapper || 0,
          prg_ram_size: (cart.prg_ram_size || 0) + (cart.prg_nvram_size || 0)
      },
      apu: Beamicom.NES.APU.new()
    }

    Mapper.reset(bus)
  end

  @doc "Advance the clock by `cycles` CPU cycles (3 PPU dots each; APU per cycle)."
  def tick(bus, cycles), do: bus |> tick_ppu(cycles) |> flush_ticks(cycles)

  @doc """
  Advance only the PPU by `cycles` CPU cycles (3 dots each). The mapper's per-scanline
  A12 edge count keeps accumulating in `ppu.irq_ticks` (reset by `flush_ticks/2`). The
  CPU calls this per cycle so NMI polling sees exact dot timing.
  """
  def tick_ppu(%__MODULE__{ppu: nil} = bus, _cycles), do: bus

  def tick_ppu(%__MODULE__{ppu: ppu} = bus, cycles),
    do: %{bus | ppu: PPU.run(ppu, cycles * 3)}

  @doc """
  Flush `cycles` of batched APU + mapper IRQ clocking. Safe to batch per instruction:
  `APU.tick/2` and `Mapper.clock_*/2` fold over the count, and the CPU only samples IRQ
  at instruction boundaries. Applies the PPU's accumulated A12 edges to the scanline-IRQ
  mappers (MMC3/MMC5), then resets the accumulator.
  """
  def flush_ticks(%__MODULE__{ppu: nil} = bus, _cycles), do: bus

  def flush_ticks(%__MODULE__{ppu: ppu} = bus, cycles) do
    # MMC3's scanline IRQ is clocked per rendered scanline; FME-7's per CPU cycle.
    # Only touch the PPU struct on the rare instructions that saw an A12 tick.
    bus =
      if ppu.irq_ticks == 0,
        do: bus,
        else: Mapper.clock_irq(%{bus | ppu: %{ppu | irq_ticks: 0}}, ppu.irq_ticks)

    # Only FME-7 (69) has a CPU-cycle IRQ; skip the call entirely otherwise.
    bus = if bus.mapper == 69, do: Mapper.clock_cpu_irq(bus, cycles), else: bus
    pending = bus.apu_pending + cycles

    if pending >= @apu_flush_threshold,
      do: %{bus | apu: Beamicom.NES.APU.tick(bus.apu, pending), apu_pending: 0},
      else: %{bus | apu_pending: pending}
  end

  @doc "Bring the APU current with all CPU cycles accumulated on the bus."
  def sync_apu(%__MODULE__{apu_pending: 0} = bus), do: bus

  def sync_apu(%__MODULE__{apu: apu, apu_pending: pending} = bus) do
    apu = apu |> Beamicom.NES.APU.tick(pending) |> Beamicom.NES.APU.flush()
    %{bus | apu: apu, apu_pending: 0}
  end

  @doc "Drain current audio samples and return `{samples, updated_bus}`."
  def take_audio(%__MODULE__{} = bus) do
    bus = sync_apu(bus)
    {samples, apu} = Beamicom.NES.APU.take_samples(bus.apu)
    {samples, %{bus | apu: apu}}
  end

  @doc "Drain audio once as `{sample_count, signed_16_bit_little_endian_pcm, updated_bus}`."
  def take_audio_pcm(%__MODULE__{} = bus) do
    bus = sync_apu(bus)
    {sample_count, pcm, apu} = Beamicom.NES.APU.take_pcm(bus.apu)
    {sample_count, pcm, %{bus | apu: apu}}
  end

  @doc """
  Whether an IRQ line is asserted (mapper or APU frame counter). A mapper's
  pending flag only drives /IRQ while its enable bit is set: disabling a scanline
  IRQ deasserts the line without clearing pending (MMC5, NESdev).
  """
  # Polled every instruction: pattern-match the flags in the heads (and read
  # apu.frame_irq directly, not via a cross-module APU.irq?/1 call).
  def irq_pending?(%__MODULE__{irq_pending: true, irq_enabled: true}), do: true
  def irq_pending?(%__MODULE__{apu: %{frame_irq: true}}), do: true
  def irq_pending?(%__MODULE__{apu: %{dmc_irq: true}}), do: true
  def irq_pending?(%__MODULE__{}), do: false

  @doc "Current NMI line level (false when headless)."
  def nmi_line?(%__MODULE__{ppu: nil}), do: false
  def nmi_line?(%__MODULE__{ppu: ppu}), do: PPU.nmi_line?(ppu)

  @doc "Consume the PPU's $2002-read NMI-suppress signal, returning {suppress?, bus}."
  def take_nmi_suppress(%__MODULE__{ppu: nil} = bus), do: {false, bus}

  # Common case (almost every instruction): nothing to consume, so don't rebuild.
  def take_nmi_suppress(%__MODULE__{ppu: %{nmi_suppress: false}} = bus), do: {false, bus}

  def take_nmi_suppress(%__MODULE__{ppu: ppu} = bus),
    do: {true, %{bus | ppu: %{ppu | nmi_suppress: false}}}

  @doc "Pure read for instruction/stack/vector fetches (never register space)."
  def peek(
        %__MODULE__{mapper: 5, mapper_state: %{prg_ram_windows: ram_windows}} = bus,
        addr
      )
      when addr >= 0x8000 do
    window = (addr - 0x8000) >>> 13
    offset = elem(bus.prg_banks, window) + (addr &&& 0x1FFF)

    if (ram_windows &&& 1 <<< window) != 0,
      do: Map.get(bus.wram, ram_key(bus, offset), 0),
      else: :binary.at(bus.prg, rem(offset, byte_size(bus.prg)))
  end

  # PRG-ROM first: code/operand fetches are by far the most common read.
  def peek(%__MODULE__{prg: prg, prg_banks: banks}, addr) when addr >= 0x8000,
    do: :binary.at(prg, elem(banks, (addr - 0x8000) >>> 13) + (addr &&& 0x1FFF))

  def peek(%__MODULE__{} = bus, addr) when addr in 0x0000..0x1FFF,
    do: :binary.at(bus.ram, addr &&& 0x07FF)

  def peek(%__MODULE__{mapper_state: %{wram_source: :rom} = ms} = bus, addr)
      when addr in 0x6000..0x7FFF do
    offset = ms.wram_bank * 0x2000 + (addr &&& 0x1FFF)
    :binary.at(bus.prg, rem(offset, byte_size(bus.prg)))
  end

  def peek(
        %__MODULE__{mapper: 4, mapper_state: %{submapper: 1} = ms} = bus,
        addr
      )
      when addr in 0x6000..0x7FFF do
    half = addr >>> 9 &&& 1

    if addr >= 0x7000 and ms.mmc6_ram_enabled and (ms.mmc6_read_mask &&& 1 <<< half) != 0,
      do: Map.get(bus.wram, 0x6000 + (addr &&& 0x03FF), 0),
      else: 0
  end

  def peek(%__MODULE__{mapper_state: %{wram_enabled: false}}, addr)
      when addr in 0x6000..0x7FFF,
      do: 0

  def peek(%__MODULE__{mapper_state: ms} = bus, addr) when addr in 0x6000..0x7FFF,
    do: Map.get(bus.wram, ram_key(bus, ms.wram_bank * 0x2000 + (addr &&& 0x1FFF)), 0)

  # MMC5 ExRAM is CPU-addressable (even executable) in the work-RAM modes (2/3).
  def peek(%__MODULE__{mapper: 5, ppu: %{exram_mode: m, exram: ex}}, addr)
      when addr in 0x5C00..0x5FFF and m >= 2,
      do: Map.get(ex, addr - 0x5C00, 0)

  def peek(%__MODULE__{}, _addr), do: 0

  @doc "Little-endian 16-bit pure read."
  def peek16(bus, addr), do: peek(bus, addr) ||| peek(bus, addr + 1) <<< 8

  @doc "Data read at an effective address. Returns {value, bus} (PPU reads mutate)."
  def read(%__MODULE__{ppu: ppu} = bus, addr) when addr in 0x2000..0x3FFF and ppu != nil do
    {value, ppu} = PPU.read_register(ppu, addr)
    {value, %{bus | ppu: ppu}}
  end

  # Controller ports: each read shifts out the next button bit.
  def read(%__MODULE__{pad1: p} = bus, 0x4016) do
    {bit, p} = read_pad(p)
    {bit, %{bus | pad1: p}}
  end

  def read(%__MODULE__{pad2: p} = bus, 0x4017) do
    {bit, p} = read_pad(p)
    {bit, %{bus | pad2: p}}
  end

  # APU status ($4015): length-counter flags + frame IRQ (reading clears it).
  def read(%__MODULE__{} = bus, 0x4015) do
    bus = sync_apu(bus)
    {value, apu} = Beamicom.NES.APU.read_status(bus.apu)
    {value, %{bus | apu: apu}}
  end

  # MMC5 expansion reads ($5204 status, $5205/$5206 multiplier).
  def read(%__MODULE__{mapper: 5} = bus, addr) when addr in 0x5000..0x5FFF,
    do: Mapper.read(bus, addr)

  def read(%__MODULE__{} = bus, addr), do: {peek(bus, addr), bus}

  # While strobing, reads return button A; otherwise shift A,B,Select,Start,Up,
  # Down,Left,Right, then 1 forever (official controller behaviour, spec §5.4).
  defp read_pad(%{strobe: true} = p), do: {p.buttons &&& 1, p}

  defp read_pad(%{index: i, buttons: b} = p),
    do: {if(i < 8, do: b >>> i &&& 1, else: 1), %{p | index: i + 1}}

  @doc "Set a controller port's (1 or 2) button state as a bitmask."
  def set_buttons(%__MODULE__{} = bus, 1, mask), do: put_in(bus.pad1.buttons, mask &&& 0xFF)
  def set_buttons(%__MODULE__{} = bus, 2, mask), do: put_in(bus.pad2.buttons, mask &&& 0xFF)

  # Strobe high resets the read index (and holds it there); dropping it latches.
  defp strobe_pad(pad, true), do: %{pad | strobe: true, index: 0}
  defp strobe_pad(pad, false), do: %{pad | strobe: false}

  def write(%__MODULE__{} = bus, addr, val) when addr in 0x0000..0x1FFF do
    i = addr &&& 0x07FF
    <<pre::binary-size(^i), _old, post::binary>> = bus.ram
    %{bus | ram: <<pre::binary, val &&& 0xFF, post::binary>>}
  end

  def write(%__MODULE__{ppu: ppu} = bus, addr, val) when addr in 0x2000..0x3FFF and ppu != nil,
    do: %{bus | ppu: PPU.write_register(ppu, addr, val)}

  # OAM DMA: copy $XX00-$XXFF into OAM via repeated $2004 writes (starts at
  # oam_addr, wraps). Flags the CPU stall (513/+1 cycles); the CPU ticks it.
  def write(%__MODULE__{ppu: ppu} = bus, 0x4014, val) when ppu != nil do
    base = (val &&& 0xFF) <<< 8
    bytes = for i <- 0..255, into: <<>>, do: <<peek(bus, base + i)>>
    %{bus | ppu: PPU.oam_dma(ppu, bytes), dma: true}
  end

  # $4016 bit 0 = strobe: high holds the shift register loaded (reads return A);
  # dropping it latches the button state for serial readout.
  def write(%__MODULE__{} = bus, 0x4016, val) do
    strobe = (val &&& 1) == 1
    %{bus | pad1: strobe_pad(bus.pad1, strobe), pad2: strobe_pad(bus.pad2, strobe)}
  end

  # $4015: the APU applies channel enables + DMC bookkeeping; if it flags a DMC
  # start, read the sample from PRG (the APU struct has no memory access) and
  # hand it over to begin playback.
  def write(%__MODULE__{} = bus, 0x4015, val) do
    bus = sync_apu(bus)
    apu = Beamicom.NES.APU.write(bus.apu, 0x4015, val)

    apu =
      if Beamicom.NES.APU.dmc_fetch?(apu) do
        {addr, len} = Beamicom.NES.APU.dmc_sample_range(apu)
        Beamicom.NES.APU.dmc_start(apu, read_dmc_sample(bus, addr, len))
      else
        apu
      end

    %{bus | apu: apu}
  end

  # APU channel + control registers ($4000-$4013, $4017 frame counter).
  def write(%__MODULE__{} = bus, addr, val) when addr in 0x4000..0x4013 or addr == 0x4017 do
    bus = sync_apu(bus)
    %{bus | apu: Beamicom.NES.APU.write(bus.apu, addr, val)}
  end

  # MMC5 sound ($5000-$5015) goes to the APU; other $5xxx are mapper registers.
  def write(%__MODULE__{mapper: 5} = bus, addr, val) when addr in 0x5000..0x5015 do
    bus = sync_apu(bus)
    %{bus | apu: Beamicom.NES.APU.mmc5_write(bus.apu, addr, val &&& 0xFF)}
  end

  # Expansion-area mapper registers — only MMC5 decodes $5xxx (others: open bus).
  def write(%__MODULE__{mapper: 5} = bus, addr, val) when addr in 0x4020..0x5FFF,
    do: Mapper.write(bus, addr, val &&& 0xFF)

  def write(%__MODULE__{mapper: 4, mapper_state: %{submapper: 1} = ms} = bus, addr, val)
      when addr in 0x6000..0x7FFF do
    half = addr >>> 9 &&& 1

    if addr >= 0x7000 and ms.mmc6_ram_enabled and
         (ms.mmc6_read_mask &&& 1 <<< half) != 0 and
         (ms.mmc6_write_mask &&& 1 <<< half) != 0 do
      %{bus | wram: Map.put(bus.wram, 0x6000 + (addr &&& 0x03FF), val &&& 0xFF)}
    else
      bus
    end
  end

  def write(
        %__MODULE__{
          mapper_state: %{
            wram_source: :ram,
            wram_enabled: true,
            wram_writable: true,
            wram_bank: bank
          }
        } = bus,
        addr,
        val
      )
      when addr in 0x6000..0x7FFF do
    key = ram_key(bus, bank * 0x2000 + (addr &&& 0x1FFF))
    %{bus | wram: Map.put(bus.wram, key, val &&& 0xFF)}
  end

  def write(%__MODULE__{} = bus, addr, _val) when addr in 0x6000..0x7FFF, do: bus

  # Sunsoft 5B expansion audio ports. Plain FME-7 cartridges ignore the audio
  # output electrically, so accepting these writes is harmless for both variants.
  def write(%__MODULE__{mapper: 69} = bus, addr, val) when addr in 0xC000..0xDFFF do
    bus = sync_apu(bus)
    %{bus | apu: Beamicom.NES.APU.sunsoft5b_select(bus.apu, val &&& 0xFF)}
  end

  def write(%__MODULE__{mapper: 69} = bus, addr, val) when addr in 0xE000..0xFFFF do
    bus = sync_apu(bus)
    %{bus | apu: Beamicom.NES.APU.sunsoft5b_write(bus.apu, val &&& 0xFF)}
  end

  # MMC5's $5114-$5116 may replace $8000-$DFFF with writable PRG-RAM.
  def write(
        %__MODULE__{mapper: 5, mapper_state: %{prg_ram_windows: ram_windows}} = bus,
        addr,
        val
      )
      when addr in 0x8000..0xFFFF do
    window = (addr - 0x8000) >>> 13

    if (ram_windows &&& 1 <<< window) != 0 and mmc5_ram_writable?(bus) do
      offset = elem(bus.prg_banks, window) + (addr &&& 0x1FFF)
      %{bus | wram: Map.put(bus.wram, ram_key(bus, offset), val &&& 0xFF)}
    else
      bus
    end
  end

  # Cartridge mapper register writes.  Discrete-logic boards commonly drive the
  # CPU data bus at the same time as ROM, so the mapper sees the bitwise AND of
  # the written value and the currently mapped ROM byte.
  def write(%__MODULE__{} = bus, addr, val) when addr in 0x8000..0xFFFF,
    do: Mapper.write(bus, addr, mapper_write_value(bus, addr, val &&& 0xFF))

  def write(%__MODULE__{} = bus, _addr, _val), do: bus

  defp ram_key(bus, offset),
    do: 0x6000 + rem(offset, max(bus.mapper_state.prg_ram_size, 0x2000))

  defp mmc5_ram_writable?(bus),
    do: bus.mapper_state.m5_protect1 == 2 and bus.mapper_state.m5_protect2 == 1

  # NES 2.0 submapper 1 marks conflict-free UxROM/CNROM boards. AxROM's default
  # submapper is conflict-free; submapper 2 explicitly has bus conflicts.
  defp mapper_write_value(
         %__MODULE__{mapper: mapper, mapper_state: %{submapper: sub}} = bus,
         addr,
         val
       )
       when mapper in [2, 3] and sub in [0, 2],
       do: val &&& peek(bus, addr)

  defp mapper_write_value(%__MODULE__{mapper: 7, mapper_state: %{submapper: 2}} = bus, addr, val),
    do: val &&& peek(bus, addr)

  defp mapper_write_value(%__MODULE__{mapper: mapper} = bus, addr, val)
       when mapper in [11, 34, 66],
       do: val &&& peek(bus, addr)

  defp mapper_write_value(_bus, _addr, val), do: val

  # DMC sample bytes from PRG ($C000-$FFFF, wrapping to $8000 past $FFFF).
  defp read_dmc_sample(bus, addr, len) do
    for i <- 0..(len - 1), into: <<>> do
      a = addr + i
      <<peek(bus, if(a > 0xFFFF, do: a - 0x8000, else: a))>>
    end
  end
end
