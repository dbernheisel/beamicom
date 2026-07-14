defmodule Beamicom.NES.Bus do
  @moduledoc """
  CPU-visible memory map: 2KB internal RAM (mirrored to $1FFF), PPU registers
  ($2000-$3FFF, mirrored every 8), OAM DMA ($4014), 8KB cartridge PRG-RAM
  ($6000-$7FFF), and mapper-banked PRG-ROM ($8000-$FFFF as two 16KB windows
  selected by `prg_lo`/`prg_hi`). APU/controller registers read back 0 for now.

  Reads split in two: `peek/2` is a pure view for the instruction stream, zero
  page pointers, the stack, and vectors (never register space); `read/2` returns
  `{value, bus}` because PPU register reads mutate. `ppu` may be nil for headless
  CPU-only runs. Writes to $8000-$FFFF are cartridge mapper register writes,
  dispatched to `Beamicom.NES.Mapper`, which also carries the MMC1 shift-register state
  (`shift`/`shift_count`/`ctrl`/`chr0`/`chr1`/`prg_reg`).

  ## Sources
    * NESdev Wiki — CPU memory map: https://www.nesdev.org/wiki/CPU_memory_map
    * NESdev Wiki — OAM DMA ($4014): https://www.nesdev.org/wiki/DMA
  """

  import Bitwise
  alias Beamicom.NES.{Mapper, PPU}

  defstruct [
    :ram,
    :wram,
    :prg,
    ppu: nil,
    dma: false,
    pad1: %{buttons: 0, index: 0, strobe: false},
    pad2: %{buttons: 0, index: 0, strobe: false},
    mapper: 0,
    # PRG as four 8KB window offsets ($8000/$A000/$C000/$E000).
    prg_banks: {0, 0x2000, 0, 0x2000},
    # MMC1 shift register + latched registers.
    shift: 0,
    shift_count: 0,
    ctrl: 0x0C,
    chr0: 0,
    chr1: 0,
    prg_reg: 0,
    # MMC3 bank registers + scanline IRQ.
    bank_select: 0,
    regs: {0, 0, 0, 0, 0, 0, 0, 0},
    irq_latch: 0,
    irq_counter: 0,
    irq_reload: false,
    irq_enabled: false,
    irq_pending: false,
    # FME-7 command latch + counter-enable.
    fme_cmd: 0,
    fme_count_on: false,
    # MMC5 PRG/CHR bank modes + 8x8 hardware multiplier + 1KB ExRAM.
    prg_mode: 3,
    chr_mode: 3,
    mul_a: 0,
    mul_b: 0,
    # MMC5 CHR bank registers (0-7 = $5120-$5127 sprite, 8-11 = $5128-$512B bg)
    # + $5130 upper bank bits.
    chr_regs: {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    chr_hi: 0,
    apu: nil
  ]

  def new(%Beamicom.NES.Cart{} = cart, ppu \\ nil) do
    bus = %__MODULE__{
      ram: %{},
      wram: %{},
      prg: cart.prg_rom,
      ppu: ppu,
      mapper: cart.mapper,
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
    bus = Mapper.clock_irq(%{bus | ppu: %{ppu | irq_ticks: 0}}, ppu.irq_ticks)
    bus = Mapper.clock_cpu_irq(bus, cycles)
    %{bus | apu: Beamicom.NES.APU.tick(bus.apu, cycles)}
  end

  @doc "Whether an IRQ line is asserted (mapper or APU frame counter)."
  def irq_pending?(%__MODULE__{irq_pending: p, apu: apu}), do: p or Beamicom.NES.APU.irq?(apu)

  @doc "Current NMI line level (false when headless)."
  def nmi_line?(%__MODULE__{ppu: nil}), do: false
  def nmi_line?(%__MODULE__{ppu: ppu}), do: PPU.nmi_line?(ppu)

  @doc "Consume the PPU's $2002-read NMI-suppress signal, returning {suppress?, bus}."
  def take_nmi_suppress(%__MODULE__{ppu: nil} = bus), do: {false, bus}

  def take_nmi_suppress(%__MODULE__{ppu: ppu} = bus),
    do: {ppu.nmi_suppress, %{bus | ppu: %{ppu | nmi_suppress: false}}}

  @doc "Pure read for instruction/stack/vector fetches (never register space)."
  def peek(%__MODULE__{} = bus, addr) when addr in 0x0000..0x1FFF,
    do: Map.get(bus.ram, addr &&& 0x07FF, 0)

  def peek(%__MODULE__{} = bus, addr) when addr in 0x6000..0x7FFF,
    do: Map.get(bus.wram, addr, 0)

  # MMC5 ExRAM is CPU-addressable (even executable) in the work-RAM modes (2/3).
  def peek(%__MODULE__{mapper: 5, ppu: %{exram_mode: m, exram: ex}}, addr)
      when addr in 0x5C00..0x5FFF and m >= 2,
      do: Map.get(ex, addr - 0x5C00, 0)

  def peek(%__MODULE__{prg: prg, prg_banks: banks}, addr) when addr in 0x8000..0xFFFF,
    do: :binary.at(prg, elem(banks, (addr - 0x8000) >>> 13) + (addr &&& 0x1FFF))

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
  def read(%__MODULE__{apu: apu} = bus, 0x4015) do
    {value, apu} = Beamicom.NES.APU.read_status(apu)
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

  def write(%__MODULE__{} = bus, addr, val) when addr in 0x0000..0x1FFF,
    do: %{bus | ram: Map.put(bus.ram, addr &&& 0x07FF, val &&& 0xFF)}

  def write(%__MODULE__{ppu: ppu} = bus, addr, val) when addr in 0x2000..0x3FFF and ppu != nil,
    do: %{bus | ppu: PPU.write_register(ppu, addr, val)}

  # OAM DMA: copy $XX00-$XXFF into OAM via repeated $2004 writes (starts at
  # oam_addr, wraps). Flags the CPU stall (513/+1 cycles); the CPU ticks it.
  def write(%__MODULE__{ppu: ppu} = bus, 0x4014, val) when ppu != nil do
    base = (val &&& 0xFF) <<< 8
    ppu = Enum.reduce(0..255, ppu, &PPU.write_register(&2, 0x2004, peek(bus, base + &1)))
    %{bus | ppu: ppu, dma: true}
  end

  # $4016 bit 0 = strobe: high holds the shift register loaded (reads return A);
  # dropping it latches the button state for serial readout.
  def write(%__MODULE__{} = bus, 0x4016, val) do
    strobe = (val &&& 1) == 1
    %{bus | pad1: strobe_pad(bus.pad1, strobe), pad2: strobe_pad(bus.pad2, strobe)}
  end

  # APU channel + control registers ($4000-$4013, $4015 enable, $4017 frame counter).
  def write(%__MODULE__{apu: apu} = bus, addr, val)
      when addr in 0x4000..0x4013 or addr == 0x4015 or addr == 0x4017,
      do: %{bus | apu: Beamicom.NES.APU.write(apu, addr, val)}

  # MMC5 sound ($5000-$5015) goes to the APU; other $5xxx are mapper registers.
  def write(%__MODULE__{mapper: 5} = bus, addr, val) when addr in 0x5000..0x5015,
    do: %{bus | apu: Beamicom.NES.APU.mmc5_write(bus.apu, addr, val &&& 0xFF)}

  # Expansion-area mapper registers — only MMC5 decodes $5xxx (others: open bus).
  def write(%__MODULE__{mapper: 5} = bus, addr, val) when addr in 0x4020..0x5FFF,
    do: Mapper.write(bus, addr, val &&& 0xFF)

  def write(%__MODULE__{} = bus, addr, val) when addr in 0x6000..0x7FFF,
    do: %{bus | wram: Map.put(bus.wram, addr, val &&& 0xFF)}

  # Cartridge mapper register writes.
  def write(%__MODULE__{} = bus, addr, val) when addr in 0x8000..0xFFFF,
    do: Mapper.write(bus, addr, val &&& 0xFF)

  def write(%__MODULE__{} = bus, _addr, _val), do: bus
end
