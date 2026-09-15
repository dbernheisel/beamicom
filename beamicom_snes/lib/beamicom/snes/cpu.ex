defmodule Beamicom.SNES.CPU do
  @moduledoc """
  Dependency-free 65C816 interpreter seed.

  Registers are stored at their native 16-bit width. In emulation mode the M
  and X status bits remain set, X/Y are truncated to eight bits, and the stack
  is constrained to page one. Every opcode fetch, operand fetch, data access,
  and internal cycle advances the SNES bus in master clocks.
  """

  import Bitwise
  require Beamicom.SNES.Bus.CPUAccess
  alias Beamicom.SNES.Bus, as: SystemBus
  alias Beamicom.SNES.Bus.CPUAccess, as: Bus
  alias Beamicom.SNES.Timing

  @compile {:inline,
            execute_deferred: 2,
            fetch8: 2,
            read_bus: 2,
            flush_events: 1,
            pending_h_irq?: 1,
            cpu_line_clocks: 1,
            poll_remaining_clocks: 1,
            poll_access_clocks: 2,
            accumulator_width: 1,
            index_width: 1,
            merge_accumulator: 3,
            mask_width: 2,
            next_bank_address: 1,
            stack_value: 2,
            flag: 3}

  @c 0x01
  @z 0x02
  @i 0x04
  @d 0x08
  @x 0x10
  @m 0x20
  @v 0x40
  @n 0x80

  defstruct a: 0,
            x: 0,
            y: 0,
            d: 0,
            s: 0x01FF,
            db: 0,
            pb: 0,
            pc: 0,
            p: 0x34,
            emulation?: true,
            waiting?: false,
            stopped?: false,
            poll_loop: nil,
            master_clocks: 0,
            instructions: 0

  @type t :: %__MODULE__{}

  @spec reset(SystemBus.t()) :: t()
  def reset(%SystemBus{} = bus) do
    pc = Bus.peek(bus, 0x00FFFC) ||| Bus.peek(bus, 0x00FFFD) <<< 8
    %__MODULE__{pc: pc}
  end

  @spec step(t(), SystemBus.t()) ::
          {:ok, t(), SystemBus.t(), pos_integer()} | {:error, term(), t(), SystemBus.t()}
  def step(%__MODULE__{} = cpu, %SystemBus{} = bus) do
    do_step(cpu, bus, :all)
  end

  @doc false
  def step_deferred(%__MODULE__{} = cpu, %SystemBus{} = bus) do
    cond do
      cpu.stopped? ->
        {:error, :cpu_stopped, cpu, Bus.flush(bus)}

      bus.nmi_pending? ->
        finish_deferred_interrupt(%{cpu | waiting?: false}, %{bus | nmi_pending?: false}, :nmi)

      bus.irq_flag? and (cpu.p &&& @i) == 0 ->
        finish_deferred_interrupt(%{cpu | waiting?: false}, bus, :irq)

      cpu.waiting? and bus.irq_flag? ->
        execute_deferred(%{cpu | waiting?: false}, bus)

      cpu.waiting? ->
        {bus, _clocks} = Bus.idle(bus)
        {:ok, cpu, flush_events(bus)}

      true ->
        case fast_forward_poll_loop(cpu, bus) do
          {:ok, cpu, bus} -> {:ok, cpu, bus}
          :keep -> execute_deferred(cpu, bus)
          :no -> execute_deferred(%{cpu | poll_loop: nil}, bus)
        end
    end
  end

  defp do_step(cpu, bus, sync) do
    start = Bus.master_clocks(bus)

    cond do
      cpu.stopped? ->
        {:error, :cpu_stopped, cpu, Bus.flush(bus)}

      bus.nmi_pending? ->
        finish_interrupt(
          %{cpu | waiting?: false},
          %{bus | nmi_pending?: false},
          :nmi,
          start,
          sync
        )

      bus.irq_flag? and (cpu.p &&& @i) == 0 ->
        finish_interrupt(%{cpu | waiting?: false}, bus, :irq, start, sync)

      cpu.waiting? and bus.irq_flag? ->
        execute_step(%{cpu | waiting?: false}, bus, start, sync)

      cpu.waiting? ->
        {bus, _clocks} = Bus.idle(bus)
        bus = sync_bus(bus, sync)
        clocks = Bus.master_clocks(bus) - start
        {:ok, %{cpu | master_clocks: cpu.master_clocks + clocks}, bus, clocks}

      true ->
        execute_step(cpu, bus, start, sync)
    end
  end

  defp execute_deferred(cpu, bus) do
    opcode_address = cpu.pb <<< 16 ||| cpu.pc
    {opcode, cpu, bus} = fetch8(cpu, bus)

    case execute(opcode, cpu, bus) do
      {:ok, cpu, bus} ->
        {:ok, %{cpu | instructions: cpu.instructions + 1}, flush_events(bus)}

      {:error, reason, cpu, bus} ->
        {:error, {reason, opcode_address}, cpu, Bus.flush(bus)}
    end
  end

  defp execute_step(cpu, bus, start, sync) do
    opcode_address = cpu.pb <<< 16 ||| cpu.pc
    {opcode, cpu, bus} = fetch8(cpu, bus)

    case execute(opcode, cpu, bus) do
      {:ok, cpu, bus} ->
        bus = sync_bus(bus, sync)
        clocks = Bus.master_clocks(bus) - start

        {:ok,
         %{
           cpu
           | master_clocks: cpu.master_clocks + clocks,
             instructions: cpu.instructions + 1
         }, bus, clocks}

      {:error, reason, cpu, bus} ->
        {:error, {reason, opcode_address}, cpu, Bus.flush(bus)}
    end
  end

  # Games commonly wait for their NMI handler to set a direct-page flag with
  # `LDA dp / BEQ -4`. Once observed, whole iterations can be charged up to
  # the next scanline boundary without allocating two CPU/bus states for each
  # pass. Interrupts are still sampled at that boundary.
  defp fast_forward_poll_loop(
         %{poll_loop: {pb, pc, address, loop_clocks}} = cpu,
         bus
       )
       when cpu.pb == pb and cpu.pc == pc do
    remaining = poll_remaining_clocks(bus)
    iterations = div(max(remaining, 0), loop_clocks)

    cond do
      iterations == 0 ->
        :keep

      Bus.peek(bus, address) == 0 ->
        cpu = %{
          cpu
          | a: cpu.a &&& 0xFF00,
            p: cpu.p |> band(bnot(@n)) |> bor(@z),
            instructions: cpu.instructions + iterations * 2
        }

        bus = %{
          bus
          | open_bus: 0xFC,
            cpu_pending_clocks: bus.cpu_pending_clocks + iterations * loop_clocks
        }

        {:ok, cpu, flush_events(bus)}

      true ->
        :no
    end
  end

  # Preserve the cached loop while executing the two-byte LDA dp that precedes
  # its branch. Otherwise the instruction boundary clears the cache before the
  # BEQ can reuse it, forcing ROM peeks and timing reconstruction every pass.
  defp fast_forward_poll_loop(%{poll_loop: {pb, pc, _address, _clocks}} = cpu, _bus)
       when cpu.pb == pb and cpu.pc == (pc + 2 &&& 0xFFFF),
       do: :keep

  defp fast_forward_poll_loop(_cpu, _bus), do: :no

  defp poll_remaining_clocks(bus) do
    current_hclock = bus.timing.hclock + bus.cpu_pending_clocks
    line_remaining = Timing.line_clocks(bus.timing) - current_hclock

    h_irq_qualified? =
      bus.irq_mode == :h or (bus.irq_mode == :hv and bus.timing.vline == bus.vtime)

    if h_irq_qualified? do
      target = bus.htime * 4

      if target > current_hclock,
        do: min(line_remaining, target - current_hclock),
        else: line_remaining
    else
      line_remaining
    end
  end

  defp mark_poll_loop(
         %{poll_loop: {pb, target, _address, _clocks}} = cpu,
         0xF0,
         0xFC,
         target,
         _bus
       )
       when (cpu.p &&& @m) != 0 and cpu.pb == pb,
       do: cpu

  defp mark_poll_loop(cpu, 0xF0, 0xFC, target, bus) when (cpu.p &&& @m) != 0 do
    opcode_address = cpu.pb <<< 16 ||| target
    operand_address = cpu.pb <<< 16 ||| (target + 1 &&& 0xFFFF)

    if Bus.peek(bus, opcode_address) == 0xA5 do
      direct = cpu.d + Bus.peek(bus, operand_address) &&& 0xFFFF

      if direct < 0x2000 do
        clocks = poll_loop_clocks(cpu, bus, target, direct)
        %{cpu | poll_loop: {cpu.pb, target, direct, clocks}}
      else
        cpu
      end
    else
      cpu
    end
  end

  defp mark_poll_loop(cpu, _opcode, _relative, _target, _bus), do: cpu

  defp poll_loop_clocks(cpu, bus, target, _direct) do
    bank = cpu.pb <<< 16

    fetch_clocks =
      poll_access_clocks(bus, bank ||| target) +
        poll_access_clocks(bus, bank ||| (target + 1 &&& 0xFFFF)) +
        8 +
        poll_access_clocks(bus, bank ||| (target + 2 &&& 0xFFFF)) +
        poll_access_clocks(bus, bank ||| (target + 3 &&& 0xFFFF))

    direct_penalty = if (cpu.d &&& 0xFF) != 0, do: 6, else: 0
    branch_page_cross? = cpu.emulation? and (target &&& 0xFF00) != (target + 4 &&& 0xFF00)
    fetch_clocks + direct_penalty + if(branch_page_cross?, do: 12, else: 6)
  end

  defp poll_access_clocks(%{cartridge: %{layout: :lorom}} = bus, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    if offset >= 0x8000 or bank in 0x40..0x6F or bank in 0xC0..0xEF,
      do: if(bus.fast_rom? and address >= 0x800000, do: 6, else: 8),
      else: SystemBus.access_clocks(bus, address)
  end

  defp poll_access_clocks(%{cartridge: %{layout: :hirom}} = bus, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    if offset >= 0x8000 or bank in 0x40..0x7D or bank in 0xC0..0xFF,
      do: if(bus.fast_rom? and address >= 0x800000, do: 6, else: 8),
      else: SystemBus.access_clocks(bus, address)
  end

  defp poll_access_clocks(bus, address), do: SystemBus.access_clocks(bus, address)

  defp execute(opcode, cpu, bus) when opcode in [0x18, 0x38, 0x58, 0x78, 0xB8, 0xD8, 0xF8] do
    p =
      case opcode do
        0x18 -> cpu.p &&& bnot(@c)
        0x38 -> cpu.p ||| @c
        0x58 -> cpu.p &&& bnot(@i)
        0x78 -> cpu.p ||| @i
        0xB8 -> cpu.p &&& bnot(@v)
        0xD8 -> cpu.p &&& bnot(@d)
        0xF8 -> cpu.p ||| @d
      end

    {bus, _clocks} = Bus.idle(bus)
    {:ok, %{cpu | p: normalize_p(p, cpu.emulation?)}, bus}
  end

  # XCE exchanges carry and emulation state. Entering emulation mode also
  # forces eight-bit register widths and a page-one stack.
  defp execute(0xFB, cpu, bus) do
    old_emulation = cpu.emulation?
    emulation? = (cpu.p &&& @c) != 0
    p = if old_emulation, do: cpu.p ||| @c, else: cpu.p &&& bnot(@c)
    {bus, _clocks} = Bus.idle(bus)

    cpu =
      %{cpu | p: normalize_p(p, emulation?), emulation?: emulation?}
      |> normalize_widths()

    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0xC2, 0xE2] do
    {mask, cpu, bus} = fetch8(cpu, bus)

    p =
      if opcode == 0xC2,
        do: cpu.p &&& bnot(mask),
        else: cpu.p ||| mask

    {bus, _clocks} = Bus.idle(bus)
    cpu = %{cpu | p: normalize_p(p, cpu.emulation?)} |> normalize_widths()
    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0xA9, 0xA2, 0xA0] do
    width = if opcode == 0xA9, do: accumulator_width(cpu), else: index_width(cpu)
    {value, cpu, bus} = fetch_width(cpu, bus, width)

    cpu =
      case opcode do
        0xA9 -> %{cpu | a: merge_accumulator(cpu.a, value, width)} |> set_zn(value, width)
        0xA2 -> %{cpu | x: value} |> set_zn(value, width)
        0xA0 -> %{cpu | y: value} |> set_zn(value, width)
      end

    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x8D, 0x8E, 0x8C] do
    {address, cpu, bus} = fetch16(cpu, bus)

    {value, width} =
      case opcode do
        0x8D -> {cpu.a, accumulator_width(cpu)}
        0x8E -> {cpu.x, index_width(cpu)}
        0x8C -> {cpu.y, index_width(cpu)}
      end

    address = cpu.db <<< 16 ||| address
    {bus, _clocks} = write_width(bus, address, value, width)

    {:ok, cpu, bus}
  end

  defp execute(0x4C, cpu, bus) do
    {address, cpu, bus} = fetch16(cpu, bus)
    {:ok, %{cpu | pc: address}, bus}
  end

  defp execute(0x5C, cpu, bus) do
    {address, cpu, bus} = fetch16(cpu, bus)
    {bank, cpu, bus} = fetch8(cpu, bus)
    {:ok, %{cpu | pb: bank, pc: address}, bus}
  end

  defp execute(0x6C, cpu, bus) do
    {pointer, cpu, bus} = fetch16(cpu, bus)
    {target, bus} = read_pointer16(bus, pointer)
    {:ok, %{cpu | pc: target}, bus}
  end

  defp execute(0x7C, cpu, bus) do
    {pointer, cpu, bus} = fetch16(cpu, bus)
    pointer = cpu.pb <<< 16 ||| (pointer + cpu.x &&& 0xFFFF)
    {bus, _clocks} = Bus.idle(bus)
    {low, bus, _clocks} = read_bus(bus, pointer)
    {high, bus, _clocks} = read_bus(bus, next_bank_address(pointer))
    {:ok, %{cpu | pc: low ||| high <<< 8}, bus}
  end

  defp execute(0xDC, cpu, bus) do
    {pointer, cpu, bus} = fetch16(cpu, bus)
    {target, bus} = read_pointer24(bus, pointer)
    {:ok, %{cpu | pb: target >>> 16, pc: target &&& 0xFFFF}, bus}
  end

  defp execute(0x80, cpu, bus) do
    {relative, cpu, bus} = fetch8(cpu, bus)
    displacement = if relative >= 0x80, do: relative - 0x100, else: relative
    {bus, _clocks} = Bus.idle(bus)
    {:ok, %{cpu | pc: cpu.pc + displacement &&& 0xFFFF}, bus}
  end

  defp execute(opcode, cpu, bus)
       when opcode in [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0] do
    {relative, cpu, bus} = fetch8(cpu, bus)

    taken? =
      case opcode do
        0x10 -> (cpu.p &&& @n) == 0
        0x30 -> (cpu.p &&& @n) != 0
        0x50 -> (cpu.p &&& @v) == 0
        0x70 -> (cpu.p &&& @v) != 0
        0x90 -> (cpu.p &&& @c) == 0
        0xB0 -> (cpu.p &&& @c) != 0
        0xD0 -> (cpu.p &&& @z) == 0
        0xF0 -> (cpu.p &&& @z) != 0
      end

    if taken? do
      displacement = if relative >= 0x80, do: relative - 0x100, else: relative
      target = cpu.pc + displacement &&& 0xFFFF
      page_cross? = cpu.emulation? and (cpu.pc &&& 0xFF00) != (target &&& 0xFF00)
      {bus, _clocks} = Bus.idle(bus, if(page_cross?, do: 2, else: 1))
      cpu = %{cpu | pc: target} |> mark_poll_loop(opcode, relative, target, bus)
      {:ok, cpu, bus}
    else
      {:ok, cpu, bus}
    end
  end

  defp execute(0x82, cpu, bus) do
    {relative, cpu, bus} = fetch16(cpu, bus)
    displacement = if relative >= 0x8000, do: relative - 0x10000, else: relative
    {bus, _clocks} = Bus.idle(bus)
    {:ok, %{cpu | pc: cpu.pc + displacement &&& 0xFFFF}, bus}
  end

  # BRK and COP consume their signature byte before stacking the return
  # address. Unlike hardware IRQ/NMI entry, neither has the two idle cycles.
  defp execute(opcode, cpu, bus) when opcode in [0x00, 0x02] do
    {_signature, cpu, bus} = fetch8(cpu, bus)
    software_interrupt(cpu, bus, if(opcode == 0x00, do: :brk, else: :cop))
  end

  # WDM is architecturally a two-byte reserved instruction. Treating its
  # signature as an opcode desynchronizes every following instruction.
  defp execute(0x42, cpu, bus) do
    {_signature, cpu, bus} = fetch8(cpu, bus)
    {:ok, cpu, bus}
  end

  defp execute(0xEA, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus)
    {:ok, cpu, bus}
  end

  defp execute(0xCB, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 2)
    {:ok, %{cpu | waiting?: true}, bus}
  end

  defp execute(0xDB, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 2)
    {:ok, %{cpu | stopped?: true}, bus}
  end

  defp execute(0xEB, cpu, bus) do
    value = cpu.a >>> 8 ||| (cpu.a &&& 0xFF) <<< 8
    {bus, _clocks} = Bus.idle(bus, 2)
    {:ok, %{cpu | a: value} |> set_zn(value &&& 0xFF, 8), bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x0A, 0x2A, 0x4A, 0x6A] do
    width = accumulator_width(cpu)
    value = mask_width(cpu.a, width)
    {result, p} = shift_rotate(opcode, value, cpu.p, width)
    {bus, _clocks} = Bus.idle(bus)
    cpu = %{cpu | a: merge_accumulator(cpu.a, result, width), p: p} |> set_zn(result, width)
    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus)
       when opcode in [
              0x06,
              0x0E,
              0x16,
              0x1E,
              0x26,
              0x2E,
              0x36,
              0x3E,
              0x46,
              0x4E,
              0x56,
              0x5E,
              0x66,
              0x6E,
              0x76,
              0x7E
            ] do
    operation = opcode &&& 0x60
    mode = rmw_mode(opcode)
    width = accumulator_width(cpu)
    {address, cpu, bus} = resolve_address(mode, cpu, bus)
    {value, bus, _clocks} = read_width(bus, address, width)
    {result, p} = shift_rotate(operation + 0x0A, value, cpu.p, width)
    {bus, _clocks} = Bus.idle(bus)
    {bus, _clocks} = write_width(bus, address, result, width)
    {:ok, %{cpu | p: p} |> set_zn(result, width), bus}
  end

  defp execute(opcode, cpu, bus)
       when opcode in [0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE] do
    width = accumulator_width(cpu)
    {address, cpu, bus} = resolve_address(rmw_mode(opcode), cpu, bus)
    {value, bus, _clocks} = read_width(bus, address, width)
    delta = if (opcode &&& 0x20) == 0, do: -1, else: 1
    result = mask_width(value + delta, width)
    {bus, _clocks} = Bus.idle(bus)
    {bus, _clocks} = write_width(bus, address, result, width)
    {:ok, set_zn(cpu, result, width), bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x04, 0x0C, 0x14, 0x1C] do
    width = accumulator_width(cpu)
    mode = if opcode in [0x04, 0x14], do: :dp, else: :abs
    {address, cpu, bus} = resolve_address(mode, cpu, bus)
    {value, bus, _clocks} = read_width(bus, address, width)
    zero? = (value &&& mask_width(cpu.a, width)) == 0
    result = if opcode in [0x04, 0x0C], do: value ||| cpu.a, else: value &&& bnot(cpu.a)
    {bus, _clocks} = Bus.idle(bus)
    {bus, _clocks} = write_width(bus, address, result, width)
    {:ok, %{cpu | p: flag(cpu.p, @z, zero?)}, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x24, 0x2C, 0x34, 0x3C, 0x89] do
    width = accumulator_width(cpu)
    mode = %{0x24 => :dp, 0x2C => :abs, 0x34 => :dpx, 0x3C => :absx, 0x89 => :imm}[opcode]
    {value, cpu, bus} = operand(mode, width, cpu, bus)
    sign = if width == 8, do: 0x80, else: 0x8000
    overflow = sign >>> 1
    p = flag(cpu.p, @z, (mask_width(cpu.a, width) &&& value) == 0)

    p =
      if mode == :imm,
        do: p,
        else: p |> flag(@n, (value &&& sign) != 0) |> flag(@v, (value &&& overflow) != 0)

    {:ok, %{cpu | p: p}, bus}
  end

  defp execute(0x40, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 2)
    {p, cpu, bus} = pull(cpu, bus)
    {low, cpu, bus} = pull(cpu, bus)
    {high, cpu, bus} = pull(cpu, bus)

    {pb, cpu, bus} =
      if cpu.emulation? do
        {cpu.pb, cpu, bus}
      else
        pull(cpu, bus)
      end

    cpu =
      %{cpu | p: normalize_p(p, cpu.emulation?), pc: low ||| high <<< 8, pb: pb}
      |> normalize_widths()

    {:ok, cpu, bus}
  end

  # Register transfers. Width follows the destination register; stack/direct
  # transfers always use their full architectural width.
  defp execute(opcode, cpu, bus)
       when opcode in [0x1B, 0x3B, 0x5B, 0x7B, 0x8A, 0x98, 0x9A, 0x9B, 0xA8, 0xAA, 0xBA, 0xBB] do
    {cpu, value, width, flags?} =
      case opcode do
        0x1B ->
          {%{cpu | s: stack_value(cpu, cpu.a)}, cpu.a, 16, false}

        0x3B ->
          {%{cpu | a: cpu.s}, cpu.s, 16, true}

        0x5B ->
          {%{cpu | d: cpu.a &&& 0xFFFF}, cpu.a, 16, true}

        0x7B ->
          {%{cpu | a: cpu.d}, cpu.d, 16, true}

        0x8A ->
          {%{cpu | a: merge_accumulator(cpu.a, cpu.x, accumulator_width(cpu))}, cpu.x,
           accumulator_width(cpu), true}

        0x98 ->
          {%{cpu | a: merge_accumulator(cpu.a, cpu.y, accumulator_width(cpu))}, cpu.y,
           accumulator_width(cpu), true}

        0x9A ->
          {%{cpu | s: stack_value(cpu, cpu.x)}, cpu.x, 16, false}

        0x9B ->
          {%{cpu | y: mask_width(cpu.x, index_width(cpu))}, cpu.x, index_width(cpu), true}

        0xA8 ->
          {%{cpu | y: mask_width(cpu.a, index_width(cpu))}, cpu.a, index_width(cpu), true}

        0xAA ->
          {%{cpu | x: mask_width(cpu.a, index_width(cpu))}, cpu.a, index_width(cpu), true}

        0xBA ->
          {%{cpu | x: mask_width(cpu.s, index_width(cpu))}, cpu.s, index_width(cpu), true}

        0xBB ->
          {%{cpu | x: mask_width(cpu.y, index_width(cpu))}, cpu.y, index_width(cpu), true}
      end

    {bus, _clocks} = Bus.idle(bus)
    {:ok, if(flags?, do: set_zn(cpu, value, width), else: cpu), bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x1A, 0x3A, 0x88, 0xC8, 0xCA, 0xE8] do
    {cpu, value, width} =
      case opcode do
        0x1A -> update_accumulator(cpu, cpu.a + 1)
        0x3A -> update_accumulator(cpu, cpu.a - 1)
        0x88 -> update_index(cpu, :y, cpu.y - 1)
        0xC8 -> update_index(cpu, :y, cpu.y + 1)
        0xCA -> update_index(cpu, :x, cpu.x - 1)
        0xE8 -> update_index(cpu, :x, cpu.x + 1)
      end

    {bus, _clocks} = Bus.idle(bus)
    {:ok, set_zn(cpu, value, width), bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x08, 0x48, 0x4B, 0x5A, 0x8B, 0xDA] do
    {value, width} =
      case opcode do
        0x08 -> {cpu.p, 8}
        0x48 -> {cpu.a, accumulator_width(cpu)}
        0x4B -> {cpu.pb, 8}
        0x5A -> {cpu.y, index_width(cpu)}
        0x8B -> {cpu.db, 8}
        0xDA -> {cpu.x, index_width(cpu)}
      end

    {bus, _clocks} = Bus.idle(bus)

    {cpu, bus} =
      if width == 16 do
        {cpu, bus} = push(cpu, bus, value >>> 8)
        push(cpu, bus, value)
      else
        push(cpu, bus, value)
      end

    {:ok, cpu, bus}
  end

  defp execute(0x0B, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus)
    {cpu, bus} = push_effective_word(cpu, bus, cpu.d)
    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x28, 0x68, 0x7A, 0xAB, 0xFA] do
    {bus, _clocks} = Bus.idle(bus, 2)

    {value, cpu, bus, width} =
      case opcode do
        0x28 ->
          {value, cpu, bus} = pull(cpu, bus)
          {value, cpu, bus, 8}

        0x68 ->
          pull_width(cpu, bus, accumulator_width(cpu))

        0x7A ->
          pull_width(cpu, bus, index_width(cpu))

        0xAB ->
          {value, cpu, bus} =
            if cpu.emulation?, do: pull_emulation_linear(cpu, bus), else: pull(cpu, bus)

          {value, cpu, bus, 8}

        0xFA ->
          pull_width(cpu, bus, index_width(cpu))
      end

    cpu =
      case opcode do
        0x28 -> %{cpu | p: normalize_p(value, cpu.emulation?)} |> normalize_widths()
        0x68 -> %{cpu | a: merge_accumulator(cpu.a, value, width)} |> set_zn(value, width)
        0x7A -> %{cpu | y: value} |> set_zn(value, width)
        0xAB -> %{cpu | db: value} |> set_zn(value, 8)
        0xFA -> %{cpu | x: value} |> set_zn(value, width)
      end

    {:ok, cpu, bus}
  end

  defp execute(0x2B, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 2)

    {value, cpu, bus} =
      if cpu.emulation?, do: pull_emulation_linear_word(cpu, bus), else: pull_word(cpu, bus)

    {:ok, %{cpu | d: value} |> set_zn(value, 16), bus}
  end

  # PEA, PEI, and PER push 16-bit effective values high byte first.
  defp execute(0xF4, cpu, bus) do
    {value, cpu, bus} = fetch16(cpu, bus)
    {cpu, bus} = push_effective_word(cpu, bus, value)
    {:ok, cpu, bus}
  end

  defp execute(0xD4, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, 0, false)
    {value, bus} = read_pointer16(bus, pointer)
    {cpu, bus} = push_effective_word(cpu, bus, value)
    {:ok, cpu, bus}
  end

  defp execute(0x62, cpu, bus) do
    {relative, cpu, bus} = fetch16(cpu, bus)
    displacement = if relative >= 0x8000, do: relative - 0x10000, else: relative
    value = cpu.pc + displacement &&& 0xFFFF
    {bus, _clocks} = Bus.idle(bus)
    {cpu, bus} = push_effective_word(cpu, bus, value)
    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x44, 0x54] do
    {destination_bank, cpu, bus} = fetch8(cpu, bus)
    {source_bank, cpu, bus} = fetch8(cpu, bus)
    index_mask = if(index_width(cpu) == 8, do: 0xFF, else: 0xFFFF)
    {value, bus, _clocks} = read_bus(bus, source_bank <<< 16 ||| (cpu.x &&& index_mask))

    {bus, _clocks} =
      Bus.write(bus, destination_bank <<< 16 ||| (cpu.y &&& index_mask), value)

    {bus, _clocks} = Bus.idle(bus, 2)
    delta = if opcode == 0x54, do: 1, else: -1
    a = cpu.a - 1 &&& 0xFFFF

    cpu = %{
      cpu
      | a: a,
        x: cpu.x + delta &&& index_mask,
        y: cpu.y + delta &&& index_mask,
        db: destination_bank,
        pc: if(a == 0xFFFF, do: cpu.pc, else: cpu.pc - 3 &&& 0xFFFF)
    }

    {:ok, cpu, bus}
  end

  defp execute(opcode, cpu, bus) when opcode in [0x64, 0x74, 0x9C, 0x9E] do
    {address, cpu, bus} =
      case opcode do
        0x64 -> direct_address(cpu, bus, 0, false)
        0x74 -> direct_address(cpu, bus, cpu.x, true)
        0x9C -> absolute_address(cpu, bus, 0)
        0x9E -> absolute_address(cpu, bus, cpu.x)
      end

    {bus, _clocks} = write_width(bus, address, 0, accumulator_width(cpu))
    {:ok, cpu, bus}
  end

  defp execute(0x20, cpu, bus) do
    {target, cpu, bus} = fetch16(cpu, bus)
    return = cpu.pc - 1 &&& 0xFFFF
    {bus, _clocks} = Bus.idle(bus)
    {cpu, bus} = push(cpu, bus, return >>> 8)
    {cpu, bus} = push(cpu, bus, return)
    {:ok, %{cpu | pc: target}, bus}
  end

  defp execute(0x22, cpu, bus) do
    {target, cpu, bus} = fetch16(cpu, bus)
    {bank, cpu, bus} = fetch8(cpu, bus)
    return = cpu.pc - 1 &&& 0xFFFF
    {bus, _clocks} = Bus.idle(bus)

    {cpu, bus} =
      if cpu.emulation? do
        push_emulation_linear(cpu, bus, [cpu.pb, return >>> 8, return])
      else
        {cpu, bus} = push(cpu, bus, cpu.pb)
        {cpu, bus} = push(cpu, bus, return >>> 8)
        push(cpu, bus, return)
      end

    {:ok, %{cpu | pb: bank, pc: target}, bus}
  end

  defp execute(0xFC, cpu, bus) do
    {pointer, cpu, bus} = fetch16(cpu, bus)
    pointer = cpu.pb <<< 16 ||| (pointer + cpu.x &&& 0xFFFF)
    return = cpu.pc - 1 &&& 0xFFFF
    {bus, _clocks} = Bus.idle(bus)
    {low, bus, _clocks} = read_bus(bus, pointer)
    {high, bus, _clocks} = read_bus(bus, next_bank_address(pointer))

    {cpu, bus} =
      if cpu.emulation? do
        push_emulation_linear(cpu, bus, [return >>> 8, return])
      else
        {cpu, bus} = push(cpu, bus, return >>> 8)
        push(cpu, bus, return)
      end

    {:ok, %{cpu | pc: low ||| high <<< 8}, bus}
  end

  defp execute(0x60, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 3)
    {low, cpu, bus} = pull(cpu, bus)
    {high, cpu, bus} = pull(cpu, bus)
    {:ok, %{cpu | pc: (low ||| high <<< 8) + 1 &&& 0xFFFF}, bus}
  end

  defp execute(0x6B, cpu, bus) do
    {bus, _clocks} = Bus.idle(bus, 2)

    {low, high, bank, cpu, bus} =
      if cpu.emulation? do
        pull_emulation_linear_long(cpu, bus)
      else
        {low, cpu, bus} = pull(cpu, bus)
        {high, cpu, bus} = pull(cpu, bus)
        {bank, cpu, bus} = pull(cpu, bus)
        {low, high, bank, cpu, bus}
      end

    {:ok, %{cpu | pb: bank, pc: (low ||| high <<< 8) + 1 &&& 0xFFFF}, bus}
  end

  defp execute(opcode, cpu, bus) do
    cond do
      instruction = load_store_instruction(opcode) ->
        case instruction do
          {:load, register, mode} -> execute_load(register, mode, cpu, bus)
          {:store, register, mode} -> execute_store(register, mode, cpu, bus)
        end

      instruction = alu_instruction(opcode) ->
        {operation, mode} = instruction
        execute_alu(operation, mode, cpu, bus)

      instruction = compare_instruction(opcode) ->
        {register, mode} = instruction
        execute_compare(register, mode, cpu, bus)

      true ->
        {:error, {:unsupported_opcode, opcode}, cpu, bus}
    end
  end

  defp fetch8(cpu, bus) do
    {value, bus, _clocks} = read_bus(bus, cpu.pb <<< 16 ||| cpu.pc)
    {value, %{cpu | pc: cpu.pc + 1 &&& 0xFFFF}, bus}
  end

  defp read_bus(%SystemBus{} = bus, address) do
    address = address &&& 0xFFFFFF
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      bank in 0x7E..0x7F ->
        value = :array.get(address - 0x7E0000, bus.wram)
        {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + 8}, 8}

      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset < 0x2000 ->
        value = :array.get(offset, bus.wram)
        {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + 8}, 8}

      bus.cartridge.layout == :lorom and
          (offset >= 0x8000 or bank in 0x40..0x6F or bank in 0xC0..0xEF) ->
        clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8
        raw_offset = (bank &&& 0x7F) <<< 15 ||| (offset &&& 0x7FFF)

        rom_offset =
          if raw_offset < bus.cartridge.size,
            do: raw_offset,
            else: Beamicom.SNES.Cartridge.mirror_offset(raw_offset, bus.cartridge.size)

        value = :binary.at(bus.cartridge.rom, rom_offset)

        {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks},
         clocks}

      bus.cartridge.layout == :hirom and
          (offset >= 0x8000 or bank in 0x40..0x7D or bank in 0xC0..0xFF) ->
        clocks = if bus.fast_rom? and address >= 0x800000, do: 6, else: 8
        raw_offset = (bank &&& 0x3F) <<< 16 ||| offset

        rom_offset =
          if raw_offset < bus.cartridge.size,
            do: raw_offset,
            else: Beamicom.SNES.Cartridge.mirror_offset(raw_offset, bus.cartridge.size)

        value = :binary.at(bus.cartridge.rom, rom_offset)

        {value, %{bus | open_bus: value, cpu_pending_clocks: bus.cpu_pending_clocks + clocks},
         clocks}

      true ->
        SystemBus.cpu_read(bus, address)
    end
  end

  defp fetch16(cpu, bus) do
    {low, cpu, bus} = fetch8(cpu, bus)
    {high, cpu, bus} = fetch8(cpu, bus)
    {low ||| high <<< 8, cpu, bus}
  end

  defp fetch24(cpu, bus) do
    {low, cpu, bus} = fetch8(cpu, bus)
    {high, cpu, bus} = fetch8(cpu, bus)
    {bank, cpu, bus} = fetch8(cpu, bus)
    {low ||| high <<< 8 ||| bank <<< 16, cpu, bus}
  end

  defp fetch_width(cpu, bus, 8), do: fetch8(cpu, bus)
  defp fetch_width(cpu, bus, 16), do: fetch16(cpu, bus)

  defp direct_address(cpu, bus, index, indexed?) do
    {operand, cpu, bus} = fetch8(cpu, bus)
    extra = if (cpu.d &&& 0xFF) != 0 or indexed?, do: 1, else: 0
    {bus, _clocks} = if extra == 1, do: Bus.idle(bus), else: {bus, 0}

    address =
      if indexed? and cpu.emulation? and (cpu.d &&& 0xFF) == 0,
        do: (cpu.d &&& 0xFF00) ||| (operand + index &&& 0xFF),
        else: cpu.d + operand + index &&& 0xFFFF

    {address, cpu, bus}
  end

  defp absolute_address(cpu, bus, index) do
    {operand, cpu, bus} = fetch16(cpu, bus)
    {(cpu.db <<< 16 ||| operand) + index &&& 0xFFFFFF, cpu, bus}
  end

  defp resolve_address(:dp, cpu, bus), do: direct_address(cpu, bus, 0, false)
  defp resolve_address(:dpx, cpu, bus), do: direct_address(cpu, bus, cpu.x, true)
  defp resolve_address(:dpy, cpu, bus), do: direct_address(cpu, bus, cpu.y, true)
  defp resolve_address(:abs, cpu, bus), do: absolute_address(cpu, bus, 0)
  defp resolve_address(:absx, cpu, bus), do: absolute_address(cpu, bus, cpu.x)
  defp resolve_address(:absy, cpu, bus), do: absolute_address(cpu, bus, cpu.y)

  defp resolve_address(:long, cpu, bus), do: fetch24(cpu, bus)

  defp resolve_address(:longx, cpu, bus) do
    {address, cpu, bus} = fetch24(cpu, bus)
    {address + cpu.x &&& 0xFFFFFF, cpu, bus}
  end

  defp resolve_address(:sr, cpu, bus) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    {bus, _clocks} = Bus.idle(bus)
    {cpu.s + offset &&& 0xFFFF, cpu, bus}
  end

  defp resolve_address(:dpix, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, cpu.x, true)
    {address, bus} = read_dp_indexed_pointer16(bus, pointer, cpu.emulation?)
    {cpu.db <<< 16 ||| address, cpu, bus}
  end

  defp resolve_address(:dpi, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, 0, false)
    {address, bus} = read_pointer16(bus, pointer)
    {cpu.db <<< 16 ||| address, cpu, bus}
  end

  defp resolve_address(:dpiy, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, 0, false)
    {address, bus} = read_pointer16(bus, pointer)
    {(cpu.db <<< 16 ||| address) + cpu.y &&& 0xFFFFFF, cpu, bus}
  end

  defp resolve_address(:dpil, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, 0, false)
    {address, bus} = read_pointer24(bus, pointer)
    {address, cpu, bus}
  end

  defp resolve_address(:dpily, cpu, bus) do
    {pointer, cpu, bus} = direct_address(cpu, bus, 0, false)
    {address, bus} = read_pointer24(bus, pointer)
    {address + cpu.y &&& 0xFFFFFF, cpu, bus}
  end

  defp resolve_address(:sriy, cpu, bus) do
    {pointer, cpu, bus} = resolve_address(:sr, cpu, bus)
    {address, bus} = read_pointer16(bus, pointer)
    {bus, _clocks} = Bus.idle(bus)
    {(cpu.db <<< 16 ||| address) + cpu.y &&& 0xFFFFFF, cpu, bus}
  end

  defp read_pointer16(bus, address) do
    {low, bus, _clocks} = read_bus(bus, address)
    {high, bus, _clocks} = read_bus(bus, address + 1 &&& 0xFFFF)
    {low ||| high <<< 8, bus}
  end

  defp read_dp_indexed_pointer16(bus, address, emulation?) do
    high_address =
      if emulation?,
        do: (address &&& 0xFF00) ||| (address + 1 &&& 0xFF),
        else: address + 1 &&& 0xFFFF

    {low, bus, _clocks} = read_bus(bus, address)
    {high, bus, _clocks} = read_bus(bus, high_address)
    {low ||| high <<< 8, bus}
  end

  defp read_pointer24(bus, address) do
    {word, bus} = read_pointer16(bus, address)
    {bank, bus, _clocks} = read_bus(bus, address + 2 &&& 0xFFFF)
    {word ||| bank <<< 16, bus}
  end

  defp read_width(bus, address, 8) do
    {value, bus, clocks} = read_bus(bus, address)
    {value, bus, clocks}
  end

  defp read_width(bus, address, 16) do
    {low, bus, low_clocks} = read_bus(bus, address)
    {high, bus, high_clocks} = read_bus(bus, address + 1 &&& 0xFFFFFF)
    {low ||| high <<< 8, bus, low_clocks + high_clocks}
  end

  defp write_width(bus, address, value, 8), do: Bus.write(bus, address, value)

  defp write_width(bus, address, value, 16) do
    {bus, low_clocks} = Bus.write(bus, address, value)
    {bus, high_clocks} = Bus.write(bus, address + 1 &&& 0xFFFFFF, value >>> 8)
    {bus, low_clocks + high_clocks}
  end

  defp next_bank_address(address), do: (address &&& 0xFF0000) ||| (address + 1 &&& 0xFFFF)

  defp rmw_mode(opcode) do
    case opcode &&& 0x1F do
      0x06 -> :dp
      0x0E -> :abs
      0x16 -> :dpx
      0x1E -> :absx
    end
  end

  defp shift_rotate(opcode, value, p, width) do
    sign = if width == 8, do: 0x80, else: 0x8000

    case opcode do
      0x0A ->
        {mask_width(value <<< 1, width), flag(p, @c, (value &&& sign) != 0)}

      0x2A ->
        {mask_width(value <<< 1 ||| if((p &&& @c) != 0, do: 1, else: 0), width),
         flag(p, @c, (value &&& sign) != 0)}

      0x4A ->
        {value >>> 1, flag(p, @c, (value &&& 1) != 0)}

      0x6A ->
        {value >>> 1 ||| if((p &&& @c) != 0, do: sign, else: 0), flag(p, @c, (value &&& 1) != 0)}
    end
  end

  defp execute_load(register, mode, cpu, bus) do
    width = if register == :a, do: accumulator_width(cpu), else: index_width(cpu)
    {address, cpu, bus} = resolve_address(mode, cpu, bus)
    {value, bus, _clocks} = read_width(bus, address, width)

    cpu =
      case register do
        :a -> %{cpu | a: merge_accumulator(cpu.a, value, width)}
        :x -> %{cpu | x: value}
        :y -> %{cpu | y: value}
      end

    {:ok, set_zn(cpu, value, width), bus}
  end

  defp execute_store(register, mode, cpu, bus) do
    width = if register == :a, do: accumulator_width(cpu), else: index_width(cpu)
    value = Map.fetch!(cpu, register)
    {address, cpu, bus} = resolve_address(mode, cpu, bus)
    {bus, _clocks} = write_width(bus, address, value, width)
    {:ok, cpu, bus}
  end

  defp execute_alu(operation, mode, cpu, bus) do
    width = accumulator_width(cpu)
    {value, cpu, bus} = operand(mode, width, cpu, bus)
    accumulator = mask_width(cpu.a, width)

    case operation do
      :ora -> alu_result(cpu, bus, accumulator ||| value, width)
      :and -> alu_result(cpu, bus, accumulator &&& value, width)
      :eor -> alu_result(cpu, bus, bxor(accumulator, value), width)
      :adc -> add(cpu, bus, accumulator, value, width)
      :sbc -> subtract(cpu, bus, accumulator, value, width)
      :cmp -> compare_result(cpu, bus, accumulator, value, width)
    end
  end

  defp execute_compare(register, mode, cpu, bus) do
    width = index_width(cpu)
    {value, cpu, bus} = operand(mode, width, cpu, bus)
    compare_result(cpu, bus, Map.fetch!(cpu, register), value, width)
  end

  defp operand(:imm, width, cpu, bus), do: fetch_width(cpu, bus, width)

  defp operand(mode, width, cpu, bus) do
    {address, cpu, bus} = resolve_address(mode, cpu, bus)
    {value, bus, _clocks} = read_width(bus, address, width)
    {value, cpu, bus}
  end

  defp alu_result(cpu, bus, value, width) do
    value = mask_width(value, width)
    cpu = %{cpu | a: merge_accumulator(cpu.a, value, width)} |> set_zn(value, width)
    {:ok, cpu, bus}
  end

  defp add(cpu, bus, left, right, width) do
    carry = if (cpu.p &&& @c) != 0, do: 1, else: 0

    if (cpu.p &&& @d) != 0 do
      {result, carry?, overflow?} = decimal_add(left, right, carry, width)
      p = cpu.p |> flag(@c, carry?) |> flag(@v, overflow?)
      alu_result(%{cpu | p: p}, bus, result, width)
    else
      binary_add(cpu, bus, left, right, carry, width)
    end
  end

  defp binary_add(cpu, bus, left, right, carry, width) do
    mask = if width == 8, do: 0xFF, else: 0xFFFF
    sign = if width == 8, do: 0x80, else: 0x8000
    sum = left + right + carry
    result = sum &&& mask
    overflow? = (bnot(bxor(left, right)) &&& bxor(left, result) &&& sign) != 0
    p = cpu.p |> flag(@c, sum > mask) |> flag(@v, overflow?)
    alu_result(%{cpu | p: p}, bus, result, width)
  end

  defp subtract(cpu, bus, left, right, width) do
    carry = if (cpu.p &&& @c) != 0, do: 1, else: 0

    if (cpu.p &&& @d) != 0 do
      {result, carry?, overflow?} = decimal_subtract(left, right, carry, width)
      p = cpu.p |> flag(@c, carry?) |> flag(@v, overflow?)
      alu_result(%{cpu | p: p}, bus, result, width)
    else
      binary_subtract(cpu, bus, left, right, carry, width)
    end
  end

  defp binary_subtract(cpu, bus, left, right, carry, width) do
    mask = if width == 8, do: 0xFF, else: 0xFFFF
    sign = if width == 8, do: 0x80, else: 0x8000
    sum = left + bxor(right, mask) + carry
    result = sum &&& mask
    overflow? = (bxor(left, right) &&& bxor(left, result) &&& sign) != 0
    p = cpu.p |> flag(@c, sum > mask) |> flag(@v, overflow?)
    alu_result(%{cpu | p: p}, bus, result, width)
  end

  # The 65C816 performs decimal correction one nibble at a time. Overflow is
  # sampled after the high-nibble addition but before that nibble's decimal
  # correction, while N and Z describe the final corrected result.
  defp decimal_add(left, right, carry, 8) do
    result = (left &&& 0x0F) + (right &&& 0x0F) + carry
    result = if result > 0x09, do: result + 0x06, else: result
    nibble_carry = if result > 0x0F, do: 0x10, else: 0
    result = (left &&& 0xF0) + (right &&& 0xF0) + nibble_carry + (result &&& 0x0F)
    overflow? = (bnot(bxor(left, right)) &&& bxor(left, result) &&& 0x80) != 0
    result = if result > 0x9F, do: result + 0x60, else: result
    {result &&& 0xFF, result > 0xFF, overflow?}
  end

  defp decimal_add(left, right, carry, 16) do
    result = (left &&& 0x000F) + (right &&& 0x000F) + carry
    result = if result > 0x0009, do: result + 0x0006, else: result
    nibble_carry = if result > 0x000F, do: 0x0010, else: 0
    result = (left &&& 0x00F0) + (right &&& 0x00F0) + nibble_carry + (result &&& 0x000F)
    result = if result > 0x009F, do: result + 0x0060, else: result
    nibble_carry = if result > 0x00FF, do: 0x0100, else: 0
    result = (left &&& 0x0F00) + (right &&& 0x0F00) + nibble_carry + (result &&& 0x00FF)
    result = if result > 0x09FF, do: result + 0x0600, else: result
    nibble_carry = if result > 0x0FFF, do: 0x1000, else: 0
    result = (left &&& 0xF000) + (right &&& 0xF000) + nibble_carry + (result &&& 0x0FFF)
    overflow? = (bnot(bxor(left, right)) &&& bxor(left, result) &&& 0x8000) != 0
    result = if result > 0x9FFF, do: result + 0x6000, else: result
    {result &&& 0xFFFF, result > 0xFFFF, overflow?}
  end

  defp decimal_subtract(left, right, carry, 8) do
    complement = bxor(right, 0xFF)
    result = (left &&& 0x0F) + (complement &&& 0x0F) + carry
    result = if result <= 0x0F, do: result - 0x06, else: result
    nibble_carry = if result > 0x0F, do: 0x10, else: 0

    result =
      (left &&& 0xF0) + (complement &&& 0xF0) + nibble_carry + (result &&& 0x0F)

    overflow? = (bnot(bxor(left, complement)) &&& bxor(left, result) &&& 0x80) != 0
    result = if result <= 0xFF, do: result - 0x60, else: result
    {result &&& 0xFF, result > 0xFF, overflow?}
  end

  defp decimal_subtract(left, right, carry, 16) do
    complement = bxor(right, 0xFFFF)
    result = (left &&& 0x000F) + (complement &&& 0x000F) + carry
    result = if result <= 0x000F, do: result - 0x0006, else: result
    nibble_carry = if result > 0x000F, do: 0x0010, else: 0

    result =
      (left &&& 0x00F0) + (complement &&& 0x00F0) + nibble_carry +
        (result &&& 0x000F)

    result = if result <= 0x00FF, do: result - 0x0060, else: result
    nibble_carry = if result > 0x00FF, do: 0x0100, else: 0

    result =
      (left &&& 0x0F00) + (complement &&& 0x0F00) + nibble_carry +
        (result &&& 0x00FF)

    result = if result <= 0x0FFF, do: result - 0x0600, else: result
    nibble_carry = if result > 0x0FFF, do: 0x1000, else: 0

    result =
      (left &&& 0xF000) + (complement &&& 0xF000) + nibble_carry +
        (result &&& 0x0FFF)

    overflow? = (bnot(bxor(left, complement)) &&& bxor(left, result) &&& 0x8000) != 0
    result = if result <= 0xFFFF, do: result - 0x6000, else: result
    {result &&& 0xFFFF, result > 0xFFFF, overflow?}
  end

  defp compare_result(cpu, bus, left, right, width) do
    result = mask_width(left - right, width)
    cpu = cpu |> Map.put(:p, flag(cpu.p, @c, left >= right)) |> set_zn(result, width)
    {:ok, cpu, bus}
  end

  defp flag(p, bit, true), do: p ||| bit
  defp flag(p, bit, false), do: p &&& bnot(bit)

  defp load_store_instruction(opcode) do
    case opcode do
      0xA1 -> {:load, :a, :dpix}
      0xA3 -> {:load, :a, :sr}
      0xA5 -> {:load, :a, :dp}
      0xA7 -> {:load, :a, :dpil}
      0xAD -> {:load, :a, :abs}
      0xAF -> {:load, :a, :long}
      0xB1 -> {:load, :a, :dpiy}
      0xB2 -> {:load, :a, :dpi}
      0xB3 -> {:load, :a, :sriy}
      0xB5 -> {:load, :a, :dpx}
      0xB7 -> {:load, :a, :dpily}
      0xB9 -> {:load, :a, :absy}
      0xBD -> {:load, :a, :absx}
      0xBF -> {:load, :a, :longx}
      0xA6 -> {:load, :x, :dp}
      0xB6 -> {:load, :x, :dpy}
      0xAE -> {:load, :x, :abs}
      0xBE -> {:load, :x, :absy}
      0xA4 -> {:load, :y, :dp}
      0xB4 -> {:load, :y, :dpx}
      0xAC -> {:load, :y, :abs}
      0xBC -> {:load, :y, :absx}
      0x81 -> {:store, :a, :dpix}
      0x83 -> {:store, :a, :sr}
      0x85 -> {:store, :a, :dp}
      0x87 -> {:store, :a, :dpil}
      0x8F -> {:store, :a, :long}
      0x91 -> {:store, :a, :dpiy}
      0x92 -> {:store, :a, :dpi}
      0x93 -> {:store, :a, :sriy}
      0x95 -> {:store, :a, :dpx}
      0x97 -> {:store, :a, :dpily}
      0x99 -> {:store, :a, :absy}
      0x9D -> {:store, :a, :absx}
      0x9F -> {:store, :a, :longx}
      0x84 -> {:store, :y, :dp}
      0x94 -> {:store, :y, :dpx}
      0x86 -> {:store, :x, :dp}
      0x96 -> {:store, :x, :dpy}
      _ -> nil
    end
  end

  defp alu_instruction(opcode) do
    operation =
      case opcode &&& 0xE0 do
        0x00 -> :ora
        0x20 -> :and
        0x40 -> :eor
        0x60 -> :adc
        0xC0 -> :cmp
        0xE0 -> :sbc
        _ -> nil
      end

    mode =
      case opcode &&& 0x1F do
        0x01 -> :dpix
        0x03 -> :sr
        0x05 -> :dp
        0x07 -> :dpil
        0x09 -> :imm
        0x0D -> :abs
        0x0F -> :long
        0x11 -> :dpiy
        0x12 -> :dpi
        0x13 -> :sriy
        0x15 -> :dpx
        0x17 -> :dpily
        0x19 -> :absy
        0x1D -> :absx
        0x1F -> :longx
        _ -> nil
      end

    if operation && mode, do: {operation, mode}, else: nil
  end

  defp compare_instruction(0xE0), do: {:x, :imm}
  defp compare_instruction(0xE4), do: {:x, :dp}
  defp compare_instruction(0xEC), do: {:x, :abs}
  defp compare_instruction(0xC0), do: {:y, :imm}
  defp compare_instruction(0xC4), do: {:y, :dp}
  defp compare_instruction(0xCC), do: {:y, :abs}
  defp compare_instruction(_opcode), do: nil

  defp finish_interrupt(cpu, bus, kind, start, sync) do
    {cpu, bus} = interrupt(cpu, bus, kind)
    bus = sync_bus(bus, sync)
    clocks = Bus.master_clocks(bus) - start
    {:ok, %{cpu | master_clocks: cpu.master_clocks + clocks}, bus, clocks}
  end

  defp finish_deferred_interrupt(cpu, bus, kind) do
    {cpu, bus} = interrupt(cpu, bus, kind)
    {:ok, cpu, flush_events(bus)}
  end

  defp sync_bus(bus, :all), do: Bus.flush(bus)
  defp sync_bus(bus, :events), do: flush_events(bus)

  defp flush_events(%{cpu_pending_clocks: 0} = bus), do: bus

  defp flush_events(bus) do
    if bus.cpu_pending_clocks >= cpu_line_clocks(bus.timing) - bus.timing.hclock or
         pending_h_irq?(bus),
       do: SystemBus.flush_cpu_timing(bus),
       else: bus
  end

  defp pending_h_irq?(%{irq_mode: mode} = bus) when mode in [:h, :hv] do
    target = bus.htime * 4
    qualified? = mode == :h or bus.timing.vline == bus.vtime

    qualified? and target > bus.timing.hclock and
      target <= bus.timing.hclock + bus.cpu_pending_clocks
  end

  defp pending_h_irq?(_bus), do: false

  defp cpu_line_clocks(%{region: :ntsc, interlace?: false, field: 1, vline: 240}), do: 1360
  defp cpu_line_clocks(%{region: :pal, interlace?: true, field: 1, vline: 311}), do: 1368
  defp cpu_line_clocks(_timing), do: 1364

  defp interrupt(cpu, bus, kind) do
    {bus, _clocks} = Bus.idle(bus, 2)

    {cpu, bus} =
      if cpu.emulation? do
        {cpu, bus}
      else
        push(cpu, bus, cpu.pb)
      end

    {cpu, bus} = push(cpu, bus, cpu.pc >>> 8)
    {cpu, bus} = push(cpu, bus, cpu.pc)
    pushed_p = if cpu.emulation?, do: cpu.p &&& bnot(@x), else: cpu.p
    {cpu, bus} = push(cpu, bus, pushed_p)
    vector = interrupt_vector(cpu.emulation?, kind)
    {low, bus, _clocks} = read_bus(bus, vector)
    {high, bus, _clocks} = read_bus(bus, vector + 1)

    cpu = %{
      cpu
      | pb: 0,
        pc: low ||| high <<< 8,
        p: cpu.p |> bor(@i) |> band(bnot(@d)) |> normalize_p(cpu.emulation?)
    }

    {cpu, bus}
  end

  defp software_interrupt(cpu, bus, kind) do
    {cpu, bus} =
      if cpu.emulation? do
        {cpu, bus}
      else
        push(cpu, bus, cpu.pb)
      end

    {cpu, bus} = push(cpu, bus, cpu.pc >>> 8)
    {cpu, bus} = push(cpu, bus, cpu.pc)
    pushed_p = if cpu.emulation?, do: cpu.p ||| @x, else: cpu.p
    {cpu, bus} = push(cpu, bus, pushed_p)
    vector = interrupt_vector(cpu.emulation?, kind)
    {low, bus, _clocks} = read_bus(bus, vector)
    {high, bus, _clocks} = read_bus(bus, vector + 1)

    cpu = %{
      cpu
      | pb: 0,
        pc: low ||| high <<< 8,
        p: cpu.p |> bor(@i) |> band(bnot(@d)) |> normalize_p(cpu.emulation?)
    }

    {:ok, cpu, bus}
  end

  defp interrupt_vector(true, :nmi), do: 0x00FFFA
  defp interrupt_vector(true, :irq), do: 0x00FFFE
  defp interrupt_vector(true, :brk), do: 0x00FFFE
  defp interrupt_vector(true, :cop), do: 0x00FFF4
  defp interrupt_vector(false, :nmi), do: 0x00FFEA
  defp interrupt_vector(false, :irq), do: 0x00FFEE
  defp interrupt_vector(false, :brk), do: 0x00FFE6
  defp interrupt_vector(false, :cop), do: 0x00FFE4

  defp push(cpu, bus, value) do
    {bus, _clocks} = Bus.write(bus, cpu.s, value)

    s =
      if cpu.emulation?,
        do: 0x0100 ||| (cpu.s - 1 &&& 0xFF),
        else: cpu.s - 1 &&& 0xFFFF

    {%{cpu | s: s}, bus}
  end

  defp push_emulation_linear(cpu, bus, values) do
    {bus, s} =
      Enum.reduce(values, {bus, cpu.s}, fn value, {bus, s} ->
        {bus, _clocks} = Bus.write(bus, s, value)
        {bus, s - 1 &&& 0xFFFF}
      end)

    {%{cpu | s: 0x0100 ||| (s &&& 0xFF)}, bus}
  end

  defp push_effective_word(%{emulation?: true} = cpu, bus, value),
    do: push_emulation_linear(cpu, bus, [value >>> 8, value])

  defp push_effective_word(cpu, bus, value) do
    {cpu, bus} = push(cpu, bus, value >>> 8)
    push(cpu, bus, value)
  end

  defp pull(cpu, bus) do
    s =
      if cpu.emulation?,
        do: 0x0100 ||| (cpu.s + 1 &&& 0xFF),
        else: cpu.s + 1 &&& 0xFFFF

    {value, bus, _clocks} = read_bus(bus, s)
    {value, %{cpu | s: s}, bus}
  end

  defp pull_emulation_linear(cpu, bus) do
    address = cpu.s + 1 &&& 0xFFFF
    {value, bus, _clocks} = read_bus(bus, address)
    {value, %{cpu | s: 0x0100 ||| (address &&& 0xFF)}, bus}
  end

  defp pull_emulation_linear_word(cpu, bus) do
    low_address = cpu.s + 1 &&& 0xFFFF
    high_address = low_address + 1 &&& 0xFFFF
    {low, bus, _clocks} = read_bus(bus, low_address)
    {high, bus, _clocks} = read_bus(bus, high_address)
    {low ||| high <<< 8, %{cpu | s: 0x0100 ||| (high_address &&& 0xFF)}, bus}
  end

  defp pull_emulation_linear_long(cpu, bus) do
    low_address = cpu.s + 1 &&& 0xFFFF
    high_address = low_address + 1 &&& 0xFFFF
    bank_address = high_address + 1 &&& 0xFFFF
    {low, bus, _clocks} = read_bus(bus, low_address)
    {high, bus, _clocks} = read_bus(bus, high_address)
    {bank, bus, _clocks} = read_bus(bus, bank_address)
    cpu = %{cpu | s: 0x0100 ||| (bank_address &&& 0xFF)}
    {low, high, bank, cpu, bus}
  end

  defp pull_word(cpu, bus) do
    {low, cpu, bus} = pull(cpu, bus)
    {high, cpu, bus} = pull(cpu, bus)
    {low ||| high <<< 8, cpu, bus}
  end

  defp pull_width(cpu, bus, 8) do
    {value, cpu, bus} = pull(cpu, bus)
    {value, cpu, bus, 8}
  end

  defp pull_width(cpu, bus, 16) do
    {low, cpu, bus} = pull(cpu, bus)
    {high, cpu, bus} = pull(cpu, bus)
    {low ||| high <<< 8, cpu, bus, 16}
  end

  defp accumulator_width(cpu), do: if((cpu.p &&& @m) == 0, do: 16, else: 8)
  defp index_width(cpu), do: if((cpu.p &&& @x) == 0, do: 16, else: 8)

  defp merge_accumulator(accumulator, value, 8),
    do: (accumulator &&& 0xFF00) ||| (value &&& 0xFF)

  defp merge_accumulator(_accumulator, value, 16), do: value

  defp mask_width(value, 8), do: value &&& 0xFF
  defp mask_width(value, 16), do: value &&& 0xFFFF

  defp stack_value(%{emulation?: true}, value), do: 0x0100 ||| (value &&& 0xFF)
  defp stack_value(_cpu, value), do: value &&& 0xFFFF

  defp update_accumulator(cpu, value) do
    width = accumulator_width(cpu)
    value = mask_width(value, width)
    {%{cpu | a: merge_accumulator(cpu.a, value, width)}, value, width}
  end

  defp update_index(cpu, register, value) do
    width = index_width(cpu)
    value = mask_width(value, width)
    {Map.put(cpu, register, value), value, width}
  end

  defp normalize_p(p, true), do: p ||| @m ||| @x
  defp normalize_p(p, false), do: p &&& 0xFF

  defp normalize_widths(%{emulation?: true} = cpu),
    do: %{cpu | x: cpu.x &&& 0xFF, y: cpu.y &&& 0xFF, s: 0x0100 ||| (cpu.s &&& 0xFF)}

  defp normalize_widths(%{p: p} = cpu) when (p &&& @x) != 0,
    do: %{cpu | x: cpu.x &&& 0xFF, y: cpu.y &&& 0xFF}

  defp normalize_widths(cpu), do: cpu

  defp set_zn(cpu, value, 8) do
    p = cpu.p &&& bnot(@z ||| @n)
    p = if (value &&& 0xFF) == 0, do: p ||| @z, else: p
    p = if (value &&& 0x80) != 0, do: p ||| @n, else: p
    %{cpu | p: p}
  end

  defp set_zn(cpu, value, 16) do
    p = cpu.p &&& bnot(@z ||| @n)
    p = if (value &&& 0xFFFF) == 0, do: p ||| @z, else: p
    p = if (value &&& 0x8000) != 0, do: p ||| @n, else: p
    %{cpu | p: p}
  end
end
