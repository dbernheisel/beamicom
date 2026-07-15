defmodule Beamicom.NES.CPU do
  @moduledoc """
  Ricoh 2A03 core — a 6502 with decimal mode disabled (spec §5.1).

  Pure functions over a `%CPU{}` struct; `step/2` executes one instruction and
  returns `{cpu, bus}`. Status is kept as the packed P byte (bit 5 always set,
  bit 4/B clear in-register; B is only asserted on the pushed copy during
  PHP/BRK). Cycle counts include page-cross and branch-taken penalties.

  ## Sources
    * NESdev Wiki — CPU (registers, status flags, stack in page 1):
      https://www.nesdev.org/wiki/CPU
    * NESdev Wiki — 6502 instruction reference & addressing modes:
      https://www.nesdev.org/obelisk-6502-guide/reference.html
    * NESdev Wiki — CPU unofficial opcodes (LAX/SAX/DCP/ISB/SLO/RLA/SRE/RRA):
      https://www.nesdev.org/wiki/CPU_unofficial_opcodes
    * Validation: nestest.nes + nestest.log (christopherpow/nes-test-roms,
      other/), cross-checked per spec §5.1 (documented section; full log after
      unofficials).
  """

  import Bitwise
  alias Beamicom.NES.{Bus, PPU}

  # nmi_line?/1 is a hot per-cycle check; keep a local inlinable copy so the
  # driving loop doesn't pay a cross-module call for it.
  @compile {:inline, nmi?: 1, poll_nmi_line: 2}

  defstruct a: 0,
            x: 0,
            y: 0,
            sp: 0xFD,
            pc: 0,
            p: 0x24,
            cycles: 0,
            nmi_prev: false,
            nmi_edge: false,
            nmi_pending: false

  @c 0x01
  @z 0x02
  @i 0x04
  @d 0x08
  @b 0x10
  @v 0x40
  @n 0x80

  # Read ops that pay +1 cycle on a page cross in indexed modes.
  @read_ops ~w(LDA LDX LDY EOR AND ORA ADC SBC CMP LAX NOP)a
  @penalty_modes ~w(abx aby izy)a

  @doc "Cold reset: load PC from the reset vector ($FFFC), SP=$FD, I set (spec §11, determinism §10)."
  def reset(bus), do: %__MODULE__{pc: Bus.peek16(bus, 0xFFFC), sp: 0xFD, p: 0x24, cycles: 7}

  @doc "Service an NMI: push PC then P (B clear), set I, jump to the $FFFA vector (7 cycles)."
  def nmi(cpu, bus) do
    {cpu, bus} = push(cpu, bus, cpu.pc >>> 8)
    {cpu, bus} = push(cpu, bus, cpu.pc &&& 0xFF)
    {cpu, bus} = push(cpu, bus, (cpu.p &&& bxor(0xFF, @b)) ||| 0x20)
    cpu = %{cpu | p: cpu.p ||| @i, pc: Bus.peek16(bus, 0xFFFA), cycles: cpu.cycles + 7}
    tick_cycles(cpu, bus, 7)
  end

  @doc "Service a maskable IRQ (e.g. MMC3): like NMI but via the $FFFE vector."
  def irq(cpu, bus) do
    {cpu, bus} = push(cpu, bus, cpu.pc >>> 8)
    {cpu, bus} = push(cpu, bus, cpu.pc &&& 0xFF)
    {cpu, bus} = push(cpu, bus, (cpu.p &&& bxor(0xFF, @b)) ||| 0x20)
    cpu = %{cpu | p: cpu.p ||| @i, pc: Bus.peek16(bus, 0xFFFE), cycles: cpu.cycles + 7}
    tick_cycles(cpu, bus, 7)
  end

  @doc """
  Execute one instruction. Returns {cpu, bus}.

  A 6502 accesses memory on its instruction's final cycle, so the clock is
  advanced by `cycles - 1` *before* `exec` runs (making any PPU register access
  observe the correct dot) and the last cycle is ticked after. Branch/page-cross
  penalties tick after the access, matching where they occur.
  """
  def step(cpu, bus) do
    opcode = Bus.peek(bus, cpu.pc)
    cpu = %{cpu | pc: cpu.pc + 1 &&& 0xFFFF}
    {op, mode, cyc} = decode(opcode)
    {addr, crossed, cpu, bus} = resolve(mode, cpu, bus)
    penalty = if crossed and op in @read_ops and mode in @penalty_modes, do: 1, else: 0
    # Only the PPU advance is split around the memory access (for exact NMI /
    # register-read dot timing). The APU + mapper-IRQ flush is batched/lazy and the
    # CPU only samples IRQ at instruction boundaries, so it runs ONCE for the whole
    # instruction, halving the per-instruction flush overhead. tick_ppu_cycles still
    # polls NMI every cycle, so NMI timing is unchanged.
    {cpu, bus} = tick_ppu_cycles(cpu, bus, cyc + penalty - 1)
    # The 6502 polls interrupts before the final cycle: an NMI asserted only on
    # the last cycle waits for the next instruction (spec §5.2 item 3).
    poll = cpu.nmi_pending
    {cpu, bus, extra} = exec(op, mode, addr, cpu, bus)
    # Re-poll at the access dot so a $2000 NMI-enable takes effect immediately,
    # then let a $2002 read within the vblank-set window cancel a latched NMI.
    cpu = poll_nmi(cpu, bus)
    {suppress, bus} = Bus.take_nmi_suppress(bus)
    cpu = if suppress, do: %{cpu | nmi_pending: false}, else: cpu
    {cpu, bus} = tick_ppu_cycles(cpu, bus, 1 + extra)
    bus = Bus.flush_ticks(bus, cyc + penalty + extra)
    cpu = %{cpu | cycles: cpu.cycles + cyc + penalty + extra}
    {cpu, bus} = if bus.dma, do: dma_stall(cpu, bus), else: {cpu, bus}

    cond do
      poll and cpu.nmi_pending -> nmi(%{cpu | nmi_pending: false}, bus)
      Bus.irq_pending?(bus) and (cpu.p &&& @i) == 0 -> irq(cpu, bus)
      true -> {cpu, bus}
    end
  end

  # OAM DMA ($4014) halts the CPU 513 cycles, +1 when it starts on an odd cycle.
  defp dma_stall(cpu, bus) do
    stall = 513 + rem(cpu.cycles, 2)
    {cpu, bus} = tick_cycles(cpu, bus, stall)
    {%{cpu | cycles: cpu.cycles + stall}, %{bus | dma: false}}
  end

  # Advance the PPU one cycle at a time (polling NMI each cycle for exact dot timing),
  # then flush the APU + mapper IRQ clocking for the whole span at once. Batching those
  # is identical to per-cycle (they fold over the count and IRQ is sampled only here).
  defp tick_cycles(cpu, bus, n) when n <= 0, do: {cpu, bus}

  defp tick_cycles(cpu, bus, n) do
    {cpu, bus} = tick_ppu_cycles(cpu, bus, n)
    {cpu, Bus.flush_ticks(bus, n)}
  end

  # Thread the PPU (not the whole Bus) through the per-cycle loop so we rebuild
  # the big Bus struct once per instruction instead of once per cycle. NMI is
  # still polled every cycle for exact edge timing. Headless (no PPU): nothing to do.
  defp tick_ppu_cycles(cpu, %{ppu: nil} = bus, _n), do: {cpu, bus}

  defp tick_ppu_cycles(cpu, bus, n) do
    {cpu, ppu} = ppu_cycles(cpu, bus.ppu, n)
    {cpu, %{bus | ppu: ppu}}
  end

  # The NMI line flips at most once across one instruction's cycles (vblank
  # set/clear; $2000 writes land in exec, not here). So when it reads the same
  # before and after the whole span, advance the PPU once and fold the per-cycle
  # NMI poll into one closed-form update. Only a span that actually flips the line
  # replays cycle-by-cycle, for exact edge timing.
  defp ppu_cycles(cpu, ppu, 0), do: {cpu, ppu}

  defp ppu_cycles(cpu, ppu, n) do
    before = nmi?(ppu)
    advanced = PPU.run(ppu, n * 3)

    if before == nmi?(advanced),
      do: {bulk_poll(cpu, before, n), advanced},
      else: ppu_cycles_slow(cpu, ppu, n)
  end

  defp ppu_cycles_slow(cpu, ppu, 0), do: {cpu, ppu}

  defp ppu_cycles_slow(cpu, ppu, n) do
    ppu = PPU.run(ppu, 3)
    ppu_cycles_slow(poll_nmi_line(cpu, nmi?(ppu)), ppu, n - 1)
  end

  # NMI output line level: vblank flag (PPUSTATUS.7) AND NMI enable (PPUCTRL.7).
  defp nmi?(ppu), do: (ppu.status &&& ppu.ctrl &&& 0x80) != 0

  # Equivalent of `n` per-cycle polls when the line held steady at `line`: a rising
  # edge can only be the very first cycle, and it propagates to nmi_pending after.
  # Steady line with no queued edge (the overwhelming common case): all three NMI
  # fields would be rewritten with their current values — skip the struct rebuild.
  defp bulk_poll(%{nmi_edge: false, nmi_prev: prev} = cpu, line, _n) when line == prev, do: cpu

  defp bulk_poll(cpu, line, 1), do: poll_nmi_line(cpu, line)

  defp bulk_poll(cpu, line, _n) do
    edge = line and not cpu.nmi_prev
    %{cpu | nmi_pending: cpu.nmi_pending or cpu.nmi_edge or edge, nmi_edge: false, nmi_prev: line}
  end

  # Detect the asserting (rising) edge of the NMI line. The 6502's edge detector
  # adds a one-cycle delay before the interrupt is recognized, so an edge seen
  # this cycle only reaches nmi_pending on the next poll.
  defp poll_nmi(cpu, bus), do: poll_nmi_line(cpu, Bus.nmi_line?(bus))

  # Common case (~every cycle): the line hasn't changed and no edge is queued, so
  # all three fields would be rewritten with their current values — skip it.
  defp poll_nmi_line(%{nmi_edge: false, nmi_prev: prev} = cpu, line) when line == prev, do: cpu

  defp poll_nmi_line(cpu, line) do
    edge = line and not cpu.nmi_prev
    %{cpu | nmi_pending: cpu.nmi_pending or cpu.nmi_edge, nmi_edge: edge, nmi_prev: line}
  end

  # --- addressing modes: return {addr | nil, page_crossed?, cpu, bus} ---

  defp resolve(:imp, cpu, bus), do: {nil, false, cpu, bus}
  defp resolve(:acc, cpu, bus), do: {nil, false, cpu, bus}

  defp resolve(:imm, cpu, bus), do: {cpu.pc, false, %{cpu | pc: cpu.pc + 1 &&& 0xFFFF}, bus}

  defp resolve(:zp, cpu, bus), do: {Bus.peek(bus, cpu.pc), false, adv(cpu, 1), bus}

  defp resolve(:zpx, cpu, bus),
    do: {Bus.peek(bus, cpu.pc) + cpu.x &&& 0xFF, false, adv(cpu, 1), bus}

  defp resolve(:zpy, cpu, bus),
    do: {Bus.peek(bus, cpu.pc) + cpu.y &&& 0xFF, false, adv(cpu, 1), bus}

  defp resolve(:abs, cpu, bus), do: {Bus.peek16(bus, cpu.pc), false, adv(cpu, 2), bus}

  defp resolve(:abx, cpu, bus), do: indexed(Bus.peek16(bus, cpu.pc), cpu.x, adv(cpu, 2), bus)
  defp resolve(:aby, cpu, bus), do: indexed(Bus.peek16(bus, cpu.pc), cpu.y, adv(cpu, 2), bus)

  defp resolve(:ind, cpu, bus) do
    ptr = Bus.peek16(bus, cpu.pc)
    # 6502 page-boundary bug: the high byte wraps within the same page.
    lo = Bus.peek(bus, ptr)
    hi = Bus.peek(bus, (ptr &&& 0xFF00) ||| (ptr + 1 &&& 0xFF))
    {lo ||| hi <<< 8, false, adv(cpu, 2), bus}
  end

  defp resolve(:izx, cpu, bus) do
    zp = Bus.peek(bus, cpu.pc) + cpu.x &&& 0xFF
    addr = Bus.peek(bus, zp) ||| Bus.peek(bus, zp + 1 &&& 0xFF) <<< 8
    {addr, false, adv(cpu, 1), bus}
  end

  defp resolve(:izy, cpu, bus) do
    zp = Bus.peek(bus, cpu.pc)
    base = Bus.peek(bus, zp) ||| Bus.peek(bus, zp + 1 &&& 0xFF) <<< 8
    addr = base + cpu.y &&& 0xFFFF
    {addr, page_crossed?(base, addr), adv(cpu, 1), bus}
  end

  defp resolve(:rel, cpu, bus) do
    off = Bus.peek(bus, cpu.pc)
    cpu = adv(cpu, 1)
    off = if off >= 0x80, do: off - 0x100, else: off
    {cpu.pc + off &&& 0xFFFF, false, cpu, bus}
  end

  defp indexed(base, idx, cpu, bus) do
    addr = base + idx &&& 0xFFFF
    {addr, page_crossed?(base, addr), cpu, bus}
  end

  defp adv(cpu, n), do: %{cpu | pc: cpu.pc + n &&& 0xFFFF}
  defp page_crossed?(a, b), do: (a &&& 0xFF00) != (b &&& 0xFF00)

  # --- execution ---

  # Loads / stores
  defp exec(:LDA, _m, addr, cpu, bus), do: load(cpu, bus, addr, :a)
  defp exec(:LDX, _m, addr, cpu, bus), do: load(cpu, bus, addr, :x)
  defp exec(:LDY, _m, addr, cpu, bus), do: load(cpu, bus, addr, :y)
  defp exec(:STA, _m, addr, cpu, bus), do: {cpu, Bus.write(bus, addr, cpu.a), 0}
  defp exec(:STX, _m, addr, cpu, bus), do: {cpu, Bus.write(bus, addr, cpu.x), 0}
  defp exec(:STY, _m, addr, cpu, bus), do: {cpu, Bus.write(bus, addr, cpu.y), 0}

  # Register transfers
  defp exec(:TAX, _m, _a, cpu, bus), do: {ld(cpu, :x, cpu.a), bus, 0}
  defp exec(:TAY, _m, _a, cpu, bus), do: {ld(cpu, :y, cpu.a), bus, 0}
  defp exec(:TXA, _m, _a, cpu, bus), do: {ld(cpu, :a, cpu.x), bus, 0}
  defp exec(:TYA, _m, _a, cpu, bus), do: {ld(cpu, :a, cpu.y), bus, 0}
  defp exec(:TSX, _m, _a, cpu, bus), do: {ld(cpu, :x, cpu.sp), bus, 0}
  defp exec(:TXS, _m, _a, cpu, bus), do: {%{cpu | sp: cpu.x}, bus, 0}

  # Stack
  defp exec(:PHA, _m, _a, cpu, bus) do
    {cpu, bus} = push(cpu, bus, cpu.a)
    {cpu, bus, 0}
  end

  defp exec(:PHP, _m, _a, cpu, bus) do
    {cpu, bus} = push(cpu, bus, cpu.p ||| @b)
    {cpu, bus, 0}
  end

  defp exec(:PLA, _m, _a, cpu, bus) do
    {cpu, v} = pull(cpu, bus)
    {ld(cpu, :a, v), bus, 0}
  end

  defp exec(:PLP, _m, _a, cpu, bus) do
    {cpu, v} = pull(cpu, bus)
    {%{cpu | p: (v &&& bxor(0xFF, @b)) ||| 0x20}, bus, 0}
  end

  # Logic
  defp exec(:AND, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {ld(cpu, :a, cpu.a &&& v), bus, 0}
  end

  defp exec(:ORA, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {ld(cpu, :a, cpu.a ||| v), bus, 0}
  end

  defp exec(:EOR, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {ld(cpu, :a, bxor(cpu.a, v)), bus, 0}
  end

  defp exec(:BIT, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)

    p =
      cpu.p
      |> set(@z, (cpu.a &&& v) == 0)
      |> set(@n, (v &&& 0x80) != 0)
      |> set(@v, (v &&& 0x40) != 0)

    {%{cpu | p: p}, bus, 0}
  end

  # Arithmetic
  defp exec(:ADC, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {adc(cpu, v), bus, 0}
  end

  defp exec(:SBC, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {adc(cpu, bxor(v, 0xFF)), bus, 0}
  end

  defp exec(:CMP, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {compare(cpu, cpu.a, v), bus, 0}
  end

  defp exec(:CPX, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {compare(cpu, cpu.x, v), bus, 0}
  end

  defp exec(:CPY, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {compare(cpu, cpu.y, v), bus, 0}
  end

  # Inc / dec
  defp exec(:INX, _m, _a, cpu, bus), do: {ld(cpu, :x, cpu.x + 1), bus, 0}
  defp exec(:INY, _m, _a, cpu, bus), do: {ld(cpu, :y, cpu.y + 1), bus, 0}
  defp exec(:DEX, _m, _a, cpu, bus), do: {ld(cpu, :x, cpu.x - 1), bus, 0}
  defp exec(:DEY, _m, _a, cpu, bus), do: {ld(cpu, :y, cpu.y - 1), bus, 0}

  defp exec(:INC, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    v = v + 1 &&& 0xFF
    {%{cpu | p: set_zn(cpu.p, v)}, Bus.write(bus, addr, v), 0}
  end

  defp exec(:DEC, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    v = v - 1 &&& 0xFF
    {%{cpu | p: set_zn(cpu.p, v)}, Bus.write(bus, addr, v), 0}
  end

  # Shifts / rotates (accumulator or memory)
  defp exec(:ASL, m, addr, cpu, bus), do: rmw(m, addr, cpu, bus, &asl/2)
  defp exec(:LSR, m, addr, cpu, bus), do: rmw(m, addr, cpu, bus, &lsr/2)
  defp exec(:ROL, m, addr, cpu, bus), do: rmw(m, addr, cpu, bus, &rol/2)
  defp exec(:ROR, m, addr, cpu, bus), do: rmw(m, addr, cpu, bus, &ror/2)

  # Jumps / subroutines
  defp exec(:JMP, _m, addr, cpu, bus), do: {%{cpu | pc: addr}, bus, 0}

  defp exec(:JSR, _m, addr, cpu, bus) do
    ret = cpu.pc - 1 &&& 0xFFFF
    {cpu, bus} = push(cpu, bus, ret >>> 8)
    {cpu, bus} = push(cpu, bus, ret &&& 0xFF)
    {%{cpu | pc: addr}, bus, 0}
  end

  defp exec(:RTS, _m, _a, cpu, bus) do
    {cpu, lo} = pull(cpu, bus)
    {cpu, hi} = pull(cpu, bus)
    {%{cpu | pc: (lo ||| hi <<< 8) + 1 &&& 0xFFFF}, bus, 0}
  end

  defp exec(:RTI, _m, _a, cpu, bus) do
    {cpu, p} = pull(cpu, bus)
    {cpu, lo} = pull(cpu, bus)
    {cpu, hi} = pull(cpu, bus)
    {%{cpu | p: (p &&& bxor(0xFF, @b)) ||| 0x20, pc: lo ||| hi <<< 8}, bus, 0}
  end

  defp exec(:BRK, _m, _a, cpu, bus) do
    cpu = adv(cpu, 1)
    {cpu, bus} = push(cpu, bus, cpu.pc >>> 8)
    {cpu, bus} = push(cpu, bus, cpu.pc &&& 0xFF)
    {cpu, bus} = push(cpu, bus, cpu.p ||| @b)
    {%{cpu | p: cpu.p ||| @i, pc: Bus.peek16(bus, 0xFFFE)}, bus, 0}
  end

  # Branches
  defp exec(:BCC, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @c) == 0, t)
  defp exec(:BCS, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @c) != 0, t)
  defp exec(:BNE, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @z) == 0, t)
  defp exec(:BEQ, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @z) != 0, t)
  defp exec(:BPL, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @n) == 0, t)
  defp exec(:BMI, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @n) != 0, t)
  defp exec(:BVC, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @v) == 0, t)
  defp exec(:BVS, _m, t, cpu, bus), do: branch(cpu, bus, (cpu.p &&& @v) != 0, t)

  # Flag ops
  defp exec(:CLC, _m, _a, cpu, bus), do: {flag(cpu, @c, false), bus, 0}
  defp exec(:SEC, _m, _a, cpu, bus), do: {flag(cpu, @c, true), bus, 0}
  defp exec(:CLI, _m, _a, cpu, bus), do: {flag(cpu, @i, false), bus, 0}
  defp exec(:SEI, _m, _a, cpu, bus), do: {flag(cpu, @i, true), bus, 0}
  defp exec(:CLD, _m, _a, cpu, bus), do: {flag(cpu, @d, false), bus, 0}
  defp exec(:SED, _m, _a, cpu, bus), do: {flag(cpu, @d, true), bus, 0}
  defp exec(:CLV, _m, _a, cpu, bus), do: {flag(cpu, @v, false), bus, 0}

  defp exec(:NOP, _m, _a, cpu, bus), do: {cpu, bus, 0}

  # --- unofficial opcodes exercised by nestest ---
  defp exec(:LAX, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    {cpu |> ld(:a, v) |> ld(:x, v), bus, 0}
  end

  defp exec(:SAX, _m, addr, cpu, bus), do: {cpu, Bus.write(bus, addr, cpu.a &&& cpu.x), 0}

  defp exec(:DCP, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    v = v - 1 &&& 0xFF
    {compare(cpu, cpu.a, v), Bus.write(bus, addr, v), 0}
  end

  defp exec(:ISB, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    v = v + 1 &&& 0xFF
    {adc(cpu, bxor(v, 0xFF)), Bus.write(bus, addr, v), 0}
  end

  defp exec(:SLO, _m, addr, cpu, bus) do
    {read, bus} = Bus.read(bus, addr)
    {p, v} = asl(cpu.p, read)
    {ld(%{cpu | p: p}, :a, cpu.a ||| v), Bus.write(bus, addr, v), 0}
  end

  defp exec(:RLA, _m, addr, cpu, bus) do
    {read, bus} = Bus.read(bus, addr)
    {p, v} = rol(cpu.p, read)
    {ld(%{cpu | p: p}, :a, cpu.a &&& v), Bus.write(bus, addr, v), 0}
  end

  defp exec(:SRE, _m, addr, cpu, bus) do
    {read, bus} = Bus.read(bus, addr)
    {p, v} = lsr(cpu.p, read)
    {ld(%{cpu | p: p}, :a, bxor(cpu.a, v)), Bus.write(bus, addr, v), 0}
  end

  defp exec(:RRA, _m, addr, cpu, bus) do
    {read, bus} = Bus.read(bus, addr)
    {p, v} = ror(cpu.p, read)
    {adc(%{cpu | p: p}, v), Bus.write(bus, addr, v), 0}
  end

  # ANC: AND #imm, then copy bit 7 into carry.
  defp exec(:ANC, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    cpu = ld(cpu, :a, cpu.a &&& v)
    {flag(cpu, @c, (cpu.a &&& 0x80) != 0), bus, 0}
  end

  # ALR: AND #imm, then LSR A.
  defp exec(:ALR, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    t = cpu.a &&& v
    cpu = ld(cpu, :a, t >>> 1)
    {flag(cpu, @c, (t &&& 0x01) != 0), bus, 0}
  end

  # ARR: AND #imm, then ROR A, with its own C/V rules (decimal disabled).
  defp exec(:ARR, _m, addr, cpu, bus) do
    {v, bus} = Bus.read(bus, addr)
    t = cpu.a &&& v
    a = t >>> 1 ||| (cpu.p &&& @c) <<< 7
    cpu = ld(cpu, :a, a)
    p = cpu.p |> set(@c, (a &&& 0x40) != 0) |> set(@v, (bxor(a >>> 6, a >>> 5) &&& 1) == 1)
    {%{cpu | p: p}, bus, 0}
  end

  # LXA: A = X = (A | magic) & #imm. The magic constant is unstable on real
  # hardware; $FF is the value blargg's checksum expects.
  defp exec(:LXA, _m, addr, cpu, bus) do
    {imm, bus} = Bus.read(bus, addr)
    v = (cpu.a ||| 0xFF) &&& imm
    {cpu |> ld(:a, v) |> ld(:x, v), bus, 0}
  end

  # SBX: X = (A & X) - #imm, carry set like CMP (no borrow).
  defp exec(:SBX, _m, addr, cpu, bus) do
    t = cpu.a &&& cpu.x
    {imm, bus} = Bus.read(bus, addr)
    cpu = ld(cpu, :x, t - imm)
    {flag(cpu, @c, t >= imm), bus, 0}
  end

  # SHY/SHX: store reg AND (high byte of base address + 1). On a page cross the
  # target's high byte is replaced by the stored value (the unstable quirk).
  defp exec(:SHY, _m, addr, cpu, bus), do: {cpu, store_high(bus, addr, cpu.x, cpu.y), 0}
  defp exec(:SHX, _m, addr, cpu, bus), do: {cpu, store_high(bus, addr, cpu.y, cpu.x), 0}

  # --- shared operation helpers ---

  defp ld(cpu, reg, v) do
    v = v &&& 0xFF
    %{cpu | reg => v, p: set_zn(cpu.p, v)}
  end

  defp adc(cpu, operand) do
    sum = cpu.a + operand + (cpu.p &&& @c)
    result = sum &&& 0xFF
    carry = sum > 0xFF
    overflow = (bxor(cpu.a, result) &&& bxor(operand, result) &&& 0x80) != 0
    %{cpu | a: result, p: cpu.p |> set_zn(result) |> set(@c, carry) |> set(@v, overflow)}
  end

  defp compare(cpu, reg, operand) do
    diff = reg - operand
    %{cpu | p: cpu.p |> set_zn(diff &&& 0xFF) |> set(@c, reg >= operand)}
  end

  defp asl(p, v), do: {set(p, @c, (v &&& 0x80) != 0), v <<< 1 &&& 0xFF}
  defp lsr(p, v), do: {set(p, @c, (v &&& 0x01) != 0), v >>> 1}
  defp rol(p, v), do: {set(p, @c, (v &&& 0x80) != 0), (v <<< 1 ||| (p &&& @c)) &&& 0xFF}
  defp ror(p, v), do: {set(p, @c, (v &&& 0x01) != 0), v >>> 1 ||| (p &&& @c) <<< 7}

  defp rmw(:acc, _addr, cpu, bus, fun) do
    {p, v} = fun.(cpu.p, cpu.a)
    {%{cpu | a: v, p: set_zn(p, v)}, bus, 0}
  end

  defp rmw(_m, addr, cpu, bus, fun) do
    {read, bus} = Bus.read(bus, addr)
    {p, v} = fun.(cpu.p, read)
    {%{cpu | p: set_zn(p, v)}, Bus.write(bus, addr, v), 0}
  end

  # LDA/LDX/LDY share the threaded read then load-with-flags.
  defp load(cpu, bus, addr, reg) do
    {v, bus} = Bus.read(bus, addr)
    {ld(cpu, reg, v), bus, 0}
  end

  # Unstable store: value = reg & (base_high + 1); on page cross the target's
  # high byte becomes that value. `index` is the register that formed the
  # effective address, so base = addr - index.
  defp store_high(bus, addr, index, reg) do
    base = addr - index &&& 0xFFFF
    value = reg &&& (base >>> 8) + 1 &&& 0xFF

    target =
      if (base &&& 0xFF00) != (addr &&& 0xFF00),
        do: (addr &&& 0xFF) ||| value <<< 8,
        else: addr

    Bus.write(bus, target, value)
  end

  defp branch(cpu, bus, false, _target), do: {cpu, bus, 0}

  defp branch(cpu, bus, true, target) do
    extra = if page_crossed?(cpu.pc, target), do: 2, else: 1
    {%{cpu | pc: target}, bus, extra}
  end

  # Stack lives in page 1.
  defp push(cpu, bus, v) do
    bus = Bus.write(bus, 0x0100 + cpu.sp, v)
    {%{cpu | sp: cpu.sp - 1 &&& 0xFF}, bus}
  end

  defp pull(cpu, bus) do
    sp = cpu.sp + 1 &&& 0xFF
    {%{cpu | sp: sp}, Bus.peek(bus, 0x0100 + sp)}
  end

  defp flag(cpu, mask, on), do: %{cpu | p: set(cpu.p, mask, on)}
  defp set(p, mask, true), do: p ||| mask
  defp set(p, mask, false), do: p &&& bxor(0xFF, mask)
  defp set_zn(p, v), do: p |> set(@z, (v &&& 0xFF) == 0) |> set(@n, (v &&& 0x80) != 0)

  # Compile-time opcode table: {operation, addressing_mode, base_cycles}.
  @table (fn ->
            official = %{
              0x69 => {:ADC, :imm, 2},
              0x65 => {:ADC, :zp, 3},
              0x75 => {:ADC, :zpx, 4},
              0x6D => {:ADC, :abs, 4},
              0x7D => {:ADC, :abx, 4},
              0x79 => {:ADC, :aby, 4},
              0x61 => {:ADC, :izx, 6},
              0x71 => {:ADC, :izy, 5},
              0x29 => {:AND, :imm, 2},
              0x25 => {:AND, :zp, 3},
              0x35 => {:AND, :zpx, 4},
              0x2D => {:AND, :abs, 4},
              0x3D => {:AND, :abx, 4},
              0x39 => {:AND, :aby, 4},
              0x21 => {:AND, :izx, 6},
              0x31 => {:AND, :izy, 5},
              0x0A => {:ASL, :acc, 2},
              0x06 => {:ASL, :zp, 5},
              0x16 => {:ASL, :zpx, 6},
              0x0E => {:ASL, :abs, 6},
              0x1E => {:ASL, :abx, 7},
              0x90 => {:BCC, :rel, 2},
              0xB0 => {:BCS, :rel, 2},
              0xF0 => {:BEQ, :rel, 2},
              0x30 => {:BMI, :rel, 2},
              0xD0 => {:BNE, :rel, 2},
              0x10 => {:BPL, :rel, 2},
              0x50 => {:BVC, :rel, 2},
              0x70 => {:BVS, :rel, 2},
              0x24 => {:BIT, :zp, 3},
              0x2C => {:BIT, :abs, 4},
              0x00 => {:BRK, :imp, 7},
              0x18 => {:CLC, :imp, 2},
              0xD8 => {:CLD, :imp, 2},
              0x58 => {:CLI, :imp, 2},
              0xB8 => {:CLV, :imp, 2},
              0x38 => {:SEC, :imp, 2},
              0xF8 => {:SED, :imp, 2},
              0x78 => {:SEI, :imp, 2},
              0xC9 => {:CMP, :imm, 2},
              0xC5 => {:CMP, :zp, 3},
              0xD5 => {:CMP, :zpx, 4},
              0xCD => {:CMP, :abs, 4},
              0xDD => {:CMP, :abx, 4},
              0xD9 => {:CMP, :aby, 4},
              0xC1 => {:CMP, :izx, 6},
              0xD1 => {:CMP, :izy, 5},
              0xE0 => {:CPX, :imm, 2},
              0xE4 => {:CPX, :zp, 3},
              0xEC => {:CPX, :abs, 4},
              0xC0 => {:CPY, :imm, 2},
              0xC4 => {:CPY, :zp, 3},
              0xCC => {:CPY, :abs, 4},
              0xC6 => {:DEC, :zp, 5},
              0xD6 => {:DEC, :zpx, 6},
              0xCE => {:DEC, :abs, 6},
              0xDE => {:DEC, :abx, 7},
              0xCA => {:DEX, :imp, 2},
              0x88 => {:DEY, :imp, 2},
              0x49 => {:EOR, :imm, 2},
              0x45 => {:EOR, :zp, 3},
              0x55 => {:EOR, :zpx, 4},
              0x4D => {:EOR, :abs, 4},
              0x5D => {:EOR, :abx, 4},
              0x59 => {:EOR, :aby, 4},
              0x41 => {:EOR, :izx, 6},
              0x51 => {:EOR, :izy, 5},
              0xE6 => {:INC, :zp, 5},
              0xF6 => {:INC, :zpx, 6},
              0xEE => {:INC, :abs, 6},
              0xFE => {:INC, :abx, 7},
              0xE8 => {:INX, :imp, 2},
              0xC8 => {:INY, :imp, 2},
              0x4C => {:JMP, :abs, 3},
              0x6C => {:JMP, :ind, 5},
              0x20 => {:JSR, :abs, 6},
              0xA9 => {:LDA, :imm, 2},
              0xA5 => {:LDA, :zp, 3},
              0xB5 => {:LDA, :zpx, 4},
              0xAD => {:LDA, :abs, 4},
              0xBD => {:LDA, :abx, 4},
              0xB9 => {:LDA, :aby, 4},
              0xA1 => {:LDA, :izx, 6},
              0xB1 => {:LDA, :izy, 5},
              0xA2 => {:LDX, :imm, 2},
              0xA6 => {:LDX, :zp, 3},
              0xB6 => {:LDX, :zpy, 4},
              0xAE => {:LDX, :abs, 4},
              0xBE => {:LDX, :aby, 4},
              0xA0 => {:LDY, :imm, 2},
              0xA4 => {:LDY, :zp, 3},
              0xB4 => {:LDY, :zpx, 4},
              0xAC => {:LDY, :abs, 4},
              0xBC => {:LDY, :abx, 4},
              0x4A => {:LSR, :acc, 2},
              0x46 => {:LSR, :zp, 5},
              0x56 => {:LSR, :zpx, 6},
              0x4E => {:LSR, :abs, 6},
              0x5E => {:LSR, :abx, 7},
              0xEA => {:NOP, :imp, 2},
              0x09 => {:ORA, :imm, 2},
              0x05 => {:ORA, :zp, 3},
              0x15 => {:ORA, :zpx, 4},
              0x0D => {:ORA, :abs, 4},
              0x1D => {:ORA, :abx, 4},
              0x19 => {:ORA, :aby, 4},
              0x01 => {:ORA, :izx, 6},
              0x11 => {:ORA, :izy, 5},
              0x48 => {:PHA, :imp, 3},
              0x08 => {:PHP, :imp, 3},
              0x68 => {:PLA, :imp, 4},
              0x28 => {:PLP, :imp, 4},
              0x2A => {:ROL, :acc, 2},
              0x26 => {:ROL, :zp, 5},
              0x36 => {:ROL, :zpx, 6},
              0x2E => {:ROL, :abs, 6},
              0x3E => {:ROL, :abx, 7},
              0x6A => {:ROR, :acc, 2},
              0x66 => {:ROR, :zp, 5},
              0x76 => {:ROR, :zpx, 6},
              0x6E => {:ROR, :abs, 6},
              0x7E => {:ROR, :abx, 7},
              0x40 => {:RTI, :imp, 6},
              0x60 => {:RTS, :imp, 6},
              0xE9 => {:SBC, :imm, 2},
              0xE5 => {:SBC, :zp, 3},
              0xF5 => {:SBC, :zpx, 4},
              0xED => {:SBC, :abs, 4},
              0xFD => {:SBC, :abx, 4},
              0xF9 => {:SBC, :aby, 4},
              0xE1 => {:SBC, :izx, 6},
              0xF1 => {:SBC, :izy, 5},
              0x85 => {:STA, :zp, 3},
              0x95 => {:STA, :zpx, 4},
              0x8D => {:STA, :abs, 4},
              0x9D => {:STA, :abx, 5},
              0x99 => {:STA, :aby, 5},
              0x81 => {:STA, :izx, 6},
              0x91 => {:STA, :izy, 6},
              0x86 => {:STX, :zp, 3},
              0x96 => {:STX, :zpy, 4},
              0x8E => {:STX, :abs, 4},
              0x84 => {:STY, :zp, 3},
              0x94 => {:STY, :zpx, 4},
              0x8C => {:STY, :abs, 4},
              0xAA => {:TAX, :imp, 2},
              0xA8 => {:TAY, :imp, 2},
              0xBA => {:TSX, :imp, 2},
              0x8A => {:TXA, :imp, 2},
              0x9A => {:TXS, :imp, 2},
              0x98 => {:TYA, :imp, 2}
            }

            unofficial = %{
              0x1A => {:NOP, :imp, 2},
              0x3A => {:NOP, :imp, 2},
              0x5A => {:NOP, :imp, 2},
              0x7A => {:NOP, :imp, 2},
              0xDA => {:NOP, :imp, 2},
              0xFA => {:NOP, :imp, 2},
              0x80 => {:NOP, :imm, 2},
              0x82 => {:NOP, :imm, 2},
              0x89 => {:NOP, :imm, 2},
              0xC2 => {:NOP, :imm, 2},
              0xE2 => {:NOP, :imm, 2},
              0x04 => {:NOP, :zp, 3},
              0x44 => {:NOP, :zp, 3},
              0x64 => {:NOP, :zp, 3},
              0x14 => {:NOP, :zpx, 4},
              0x34 => {:NOP, :zpx, 4},
              0x54 => {:NOP, :zpx, 4},
              0x74 => {:NOP, :zpx, 4},
              0xD4 => {:NOP, :zpx, 4},
              0xF4 => {:NOP, :zpx, 4},
              0x0C => {:NOP, :abs, 4},
              0x1C => {:NOP, :abx, 4},
              0x3C => {:NOP, :abx, 4},
              0x5C => {:NOP, :abx, 4},
              0x7C => {:NOP, :abx, 4},
              0xDC => {:NOP, :abx, 4},
              0xFC => {:NOP, :abx, 4},
              0xEB => {:SBC, :imm, 2},
              0xA7 => {:LAX, :zp, 3},
              0xB7 => {:LAX, :zpy, 4},
              0xAF => {:LAX, :abs, 4},
              0xBF => {:LAX, :aby, 4},
              0xA3 => {:LAX, :izx, 6},
              0xB3 => {:LAX, :izy, 5},
              0x87 => {:SAX, :zp, 3},
              0x97 => {:SAX, :zpy, 4},
              0x8F => {:SAX, :abs, 4},
              0x83 => {:SAX, :izx, 6},
              0xC7 => {:DCP, :zp, 5},
              0xD7 => {:DCP, :zpx, 6},
              0xCF => {:DCP, :abs, 6},
              0xDF => {:DCP, :abx, 7},
              0xDB => {:DCP, :aby, 7},
              0xC3 => {:DCP, :izx, 8},
              0xD3 => {:DCP, :izy, 8},
              0xE7 => {:ISB, :zp, 5},
              0xF7 => {:ISB, :zpx, 6},
              0xEF => {:ISB, :abs, 6},
              0xFF => {:ISB, :abx, 7},
              0xFB => {:ISB, :aby, 7},
              0xE3 => {:ISB, :izx, 8},
              0xF3 => {:ISB, :izy, 8},
              0x07 => {:SLO, :zp, 5},
              0x17 => {:SLO, :zpx, 6},
              0x0F => {:SLO, :abs, 6},
              0x1F => {:SLO, :abx, 7},
              0x1B => {:SLO, :aby, 7},
              0x03 => {:SLO, :izx, 8},
              0x13 => {:SLO, :izy, 8},
              0x27 => {:RLA, :zp, 5},
              0x37 => {:RLA, :zpx, 6},
              0x2F => {:RLA, :abs, 6},
              0x3F => {:RLA, :abx, 7},
              0x3B => {:RLA, :aby, 7},
              0x23 => {:RLA, :izx, 8},
              0x33 => {:RLA, :izy, 8},
              0x47 => {:SRE, :zp, 5},
              0x57 => {:SRE, :zpx, 6},
              0x4F => {:SRE, :abs, 6},
              0x5F => {:SRE, :abx, 7},
              0x5B => {:SRE, :aby, 7},
              0x43 => {:SRE, :izx, 8},
              0x53 => {:SRE, :izy, 8},
              0x67 => {:RRA, :zp, 5},
              0x77 => {:RRA, :zpx, 6},
              0x6F => {:RRA, :abs, 6},
              0x7F => {:RRA, :abx, 7},
              0x7B => {:RRA, :aby, 7},
              0x63 => {:RRA, :izx, 8},
              0x73 => {:RRA, :izy, 8},
              0x0B => {:ANC, :imm, 2},
              0x2B => {:ANC, :imm, 2},
              0x4B => {:ALR, :imm, 2},
              0x6B => {:ARR, :imm, 2},
              0xAB => {:LXA, :imm, 2},
              0xCB => {:SBX, :imm, 2},
              0x9C => {:SHY, :abx, 5},
              0x9E => {:SHX, :aby, 5}
            }

            merged = Map.merge(official, unofficial)

            0..255
            |> Enum.map(fn i -> Map.get(merged, i, {:NOP, :imp, 2}) end)
            |> List.to_tuple()
          end).()

  defp decode(op), do: elem(@table, op)
end
