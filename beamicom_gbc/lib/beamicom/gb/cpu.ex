defmodule Beamicom.GB.CPU do
  @moduledoc """
  Functional Sharp SM83 (LR35902) CPU core.

  `step/2` executes one instruction and returns `{cpu, bus, m_cycles}`. The CPU
  and concrete `Beamicom.GB.Bus` are separate values owned by the future
  machine scheduler. Memory accesses are static module calls: the hot path has
  no protocols, runtime opcode maps, closures, processes, tracing, or
  cumulative-time updates.

  All documented base and CB-prefixed instructions are implemented, including
  conditional timings, interrupt dispatch, HALT behavior, and invalid-opcode
  lock-up. `STOP` also performs a prepared CGB speed switch through the bus.
  """

  import Bitwise
  alias Beamicom.GB.Bus

  @flag_z 0x80
  @flag_n 0x40
  @flag_h 0x20
  @flag_c 0x10

  @interrupt_vectors {0x40, 0x48, 0x50, 0x58, 0x60}

  @compile {:inline,
            flag?: 2,
            get_r: 3,
            put_r: 4,
            get_rp: 2,
            put_rp: 3,
            get_rp2: 2,
            put_rp2: 3,
            indirect_address: 2,
            condition?: 2,
            inc16: 1,
            dec16: 1}

  defstruct a: 0,
            f: 0,
            b: 0,
            c: 0,
            d: 0,
            e: 0,
            h: 0,
            l: 0,
            sp: 0,
            pc: 0,
            ime_state: :disabled,
            run_state: :running,
            halt_bug: false

  @type t :: %__MODULE__{
          a: byte(),
          f: byte(),
          b: byte(),
          c: byte(),
          d: byte(),
          e: byte(),
          h: byte(),
          l: byte(),
          sp: 0..0xFFFF,
          pc: 0..0xFFFF,
          ime_state: :disabled | :scheduled | :enabled,
          run_state: :running | :halted | :stopped | :locked,
          halt_bug: boolean()
        }

  @doc "Creates a CPU, accepting register and control fields as options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    cpu = struct!(__MODULE__, opts)
    %{cpu | f: cpu.f &&& 0xF0}
  end

  @doc "Returns whether one of `:z`, `:n`, `:h`, or `:c` is set."
  @spec flag?(t(), :z | :n | :h | :c) :: boolean()
  def flag?(%__MODULE__{f: f}, :z), do: (f &&& @flag_z) != 0
  def flag?(%__MODULE__{f: f}, :n), do: (f &&& @flag_n) != 0
  def flag?(%__MODULE__{f: f}, :h), do: (f &&& @flag_h) != 0
  def flag?(%__MODULE__{f: f}, :c), do: (f &&& @flag_c) != 0

  @doc "Executes one instruction and reports the updated CPU, bus, and M-cycles."
  @spec step(t(), Bus.t()) :: {t(), Bus.t(), pos_integer()}
  def step(%__MODULE__{run_state: :locked} = cpu, %Bus{} = bus),
    do: {cpu, Bus.idle(bus, 1), 1}

  def step(%__MODULE__{run_state: :stopped} = cpu, %Bus{} = bus) do
    case Bus.take_stop_wake(bus) do
      {false, bus} -> {cpu, bus, 1}
      {true, bus} -> step(%{cpu | run_state: :running}, bus)
    end
  end

  # Literal field heads keep the usual no-interrupt instruction path small.
  def step(%__MODULE__{} = cpu, %Bus{ie: 0} = bus), do: step_without_interrupt(cpu, bus)

  def step(%__MODULE__{} = cpu, %Bus{interrupt_flags: 0} = bus),
    do: step_without_interrupt(cpu, bus)

  def step(%__MODULE__{} = cpu, %Bus{ie: ie, interrupt_flags: flags} = bus) do
    case {ie &&& flags &&& 0x1F, cpu.ime_state, cpu.run_state} do
      {0, _, _} -> step_without_interrupt(cpu, bus)
      {pending, :enabled, _} -> service_interrupt(cpu, bus, pending)
      {_pending, _, :halted} -> step_without_interrupt(%{cpu | run_state: :running}, bus)
      {_pending, _, _} -> step_without_interrupt(cpu, bus)
    end
  end

  defp step_without_interrupt(%__MODULE__{run_state: :halted} = cpu, bus),
    do: {cpu, Bus.idle(bus, 1), 1}

  defp step_without_interrupt(cpu, bus) do
    enable_ime? = cpu.ime_state == :scheduled
    {opcode, cpu, bus} = fetch8(cpu, bus)
    {cpu, bus, cycles} = execute(cpu, bus, opcode)
    {advance_ime(cpu, enable_ime?), bus, cycles}
  end

  @doc "Explicitly clears HALT/STOP state."
  @spec wake(t()) :: t()
  def wake(%__MODULE__{} = cpu), do: %{cpu | run_state: :running}

  # Build literal opcode heads once at compile time. This leaves the runtime
  # dispatcher as a direct select instead of decoding fields or indexing a
  # tuple for every emulated instruction.
  for opcode <- 0x00..0xFF do
    x = opcode >>> 6
    y = opcode >>> 3 &&& 0x07
    z = opcode &&& 0x07
    p = y >>> 1
    q = y &&& 0x01

    defp execute(cpu, bus, unquote(opcode)),
      do:
        execute(
          cpu,
          bus,
          unquote(opcode),
          unquote(x),
          unquote(y),
          unquote(z),
          unquote(p),
          unquote(q)
        )
  end

  # x = 0
  defp execute(cpu, bus, _opcode, 0, 0, 0, _p, _q), do: {cpu, bus, 1}

  defp execute(cpu, bus, _opcode, 0, 1, 0, _p, _q) do
    {address, cpu, bus} = fetch16(cpu, bus)
    bus = Bus.write_cycle(bus, address, cpu.sp &&& 0xFF)
    {cpu, Bus.write_cycle(bus, inc16(address), cpu.sp >>> 8), 5}
  end

  defp execute(cpu, bus, _opcode, 0, 2, 0, _p, _q) do
    # STOP is encoded with a padding byte, but the pair consumes one M-cycle.
    cpu = %{cpu | pc: inc16(cpu.pc)}

    case Bus.stop(bus) do
      {:stop, bus} -> {%{cpu | run_state: :stopped}, bus, 1}
      {:speed_switch, bus} -> {cpu, bus, 1}
    end
  end

  defp execute(cpu, bus, _opcode, 0, 3, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    {%{cpu | pc: add_signed(cpu.pc, offset)}, Bus.idle(bus, 1), 3}
  end

  defp execute(cpu, bus, _opcode, 0, y, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)

    if condition?(cpu, y - 4),
      do: {%{cpu | pc: add_signed(cpu.pc, offset)}, Bus.idle(bus, 1), 3},
      else: {cpu, bus, 2}
  end

  defp execute(cpu, bus, _opcode, 0, _y, 1, p, 0) do
    {value, cpu, bus} = fetch16(cpu, bus)
    {put_rp(cpu, p, value), bus, 3}
  end

  defp execute(cpu, bus, _opcode, 0, _y, 1, p, 1) do
    hl = get_rp(cpu, 2)
    value = get_rp(cpu, p)
    result = band(hl + value, 0xFFFF)

    f =
      flags(
        flag?(cpu, :z),
        false,
        (hl &&& 0x0FFF) + (value &&& 0x0FFF) > 0x0FFF,
        hl + value > 0xFFFF
      )

    {%{put_rp(cpu, 2, result) | f: f}, Bus.idle(bus, 1), 2}
  end

  defp execute(cpu, bus, _opcode, 0, _y, 2, p, 0) do
    address = indirect_address(cpu, p)
    {advance_hl(cpu, p), Bus.write_cycle(bus, address, cpu.a), 2}
  end

  defp execute(cpu, bus, _opcode, 0, _y, 2, p, 1) do
    address = indirect_address(cpu, p)
    {value, bus} = Bus.read_cycle(bus, address)
    {advance_hl(%{cpu | a: value}, p), bus, 2}
  end

  defp execute(cpu, bus, _opcode, 0, _y, 3, p, 0),
    do: {put_rp(cpu, p, inc16(get_rp(cpu, p))), Bus.idle(bus, 1), 2}

  defp execute(cpu, bus, _opcode, 0, _y, 3, p, 1),
    do: {put_rp(cpu, p, dec16(get_rp(cpu, p))), Bus.idle(bus, 1), 2}

  defp execute(cpu, bus, _opcode, 0, y, 4, _p, _q) do
    {value, bus} = get_r(cpu, bus, y)
    result = band(value + 1, 0xFF)
    f = flags(result == 0, false, (value &&& 0x0F) == 0x0F, flag?(cpu, :c))
    {cpu, bus} = put_r(%{cpu | f: f}, bus, y, result)
    {cpu, bus, if(y == 6, do: 3, else: 1)}
  end

  defp execute(cpu, bus, _opcode, 0, y, 5, _p, _q) do
    {value, bus} = get_r(cpu, bus, y)
    result = band(value - 1, 0xFF)
    f = flags(result == 0, true, (value &&& 0x0F) == 0, flag?(cpu, :c))
    {cpu, bus} = put_r(%{cpu | f: f}, bus, y, result)
    {cpu, bus, if(y == 6, do: 3, else: 1)}
  end

  defp execute(cpu, bus, _opcode, 0, y, 6, _p, _q) do
    {value, cpu, bus} = fetch8(cpu, bus)
    {cpu, bus} = put_r(cpu, bus, y, value)
    {cpu, bus, if(y == 6, do: 3, else: 2)}
  end

  defp execute(cpu, bus, _opcode, 0, y, 7, _p, _q) do
    {cpu, cycles} = accumulator_misc(cpu, y)
    {cpu, bus, cycles}
  end

  # x = 1: 8-bit loads, with $76 repurposed as HALT.
  defp execute(cpu, bus, 0x76, 1, _y, _z, _p, _q) do
    if cpu.ime_state != :enabled and (bus.ie &&& bus.interrupt_flags &&& 0x1F) != 0,
      do: {%{cpu | halt_bug: true}, bus, 1},
      else: {%{cpu | run_state: :halted}, bus, 1}
  end

  defp execute(cpu, bus, _opcode, 1, y, z, _p, _q) do
    {value, bus} = get_r(cpu, bus, z)
    {cpu, bus} = put_r(cpu, bus, y, value)
    {cpu, bus, if(y == 6 or z == 6, do: 2, else: 1)}
  end

  # x = 2: ALU A,r8.
  defp execute(cpu, bus, _opcode, 2, y, z, _p, _q) do
    {value, bus} = get_r(cpu, bus, z)
    {alu(cpu, y, value), bus, if(z == 6, do: 2, else: 1)}
  end

  # x = 3
  defp execute(cpu, bus, _opcode, 3, y, 0, _p, _q) when y < 4 do
    if condition?(cpu, y) do
      bus = Bus.idle(bus, 1)
      {value, cpu, bus} = pop16(cpu, bus)
      {%{cpu | pc: value}, Bus.idle(bus, 1), 5}
    else
      {cpu, Bus.idle(bus, 1), 2}
    end
  end

  defp execute(cpu, bus, _opcode, 3, 4, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    {cpu, Bus.write_cycle(bus, 0xFF00 + offset, cpu.a), 3}
  end

  defp execute(cpu, bus, _opcode, 3, 5, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    sp = cpu.sp
    result = add_signed(sp, offset)

    f =
      flags(false, false, (sp &&& 0x0F) + (offset &&& 0x0F) > 0x0F, (sp &&& 0xFF) + offset > 0xFF)

    {%{cpu | sp: result, f: f}, Bus.idle(bus, 2), 4}
  end

  defp execute(cpu, bus, _opcode, 3, 6, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    {value, bus} = Bus.read_cycle(bus, 0xFF00 + offset)
    {%{cpu | a: value}, bus, 3}
  end

  defp execute(cpu, bus, _opcode, 3, 7, 0, _p, _q) do
    {offset, cpu, bus} = fetch8(cpu, bus)
    sp = cpu.sp
    result = add_signed(sp, offset)

    f =
      flags(false, false, (sp &&& 0x0F) + (offset &&& 0x0F) > 0x0F, (sp &&& 0xFF) + offset > 0xFF)

    {put_rp(%{cpu | f: f}, 2, result), Bus.idle(bus, 1), 3}
  end

  defp execute(cpu, bus, _opcode, 3, _y, 1, p, 0) do
    {value, cpu, bus} = pop16(cpu, bus)
    {put_rp2(cpu, p, value), bus, 3}
  end

  defp execute(cpu, bus, _opcode, 3, _y, 1, 0, 1) do
    {value, cpu, bus} = pop16(cpu, bus)
    {%{cpu | pc: value}, Bus.idle(bus, 1), 4}
  end

  defp execute(cpu, bus, _opcode, 3, _y, 1, 1, 1) do
    {value, cpu, bus} = pop16(cpu, bus)
    {%{cpu | pc: value, ime_state: :enabled}, Bus.idle(bus, 1), 4}
  end

  defp execute(cpu, bus, _opcode, 3, _y, 1, 2, 1), do: {%{cpu | pc: get_rp(cpu, 2)}, bus, 1}

  defp execute(cpu, bus, _opcode, 3, _y, 1, 3, 1),
    do: {%{cpu | sp: get_rp(cpu, 2)}, Bus.idle(bus, 1), 2}

  defp execute(cpu, bus, _opcode, 3, y, 2, _p, _q) when y < 4 do
    {address, cpu, bus} = fetch16(cpu, bus)

    if condition?(cpu, y),
      do: {%{cpu | pc: address}, Bus.idle(bus, 1), 4},
      else: {cpu, bus, 3}
  end

  defp execute(cpu, bus, _opcode, 3, 4, 2, _p, _q),
    do: {cpu, Bus.write_cycle(bus, 0xFF00 + cpu.c, cpu.a), 2}

  defp execute(cpu, bus, _opcode, 3, 5, 2, _p, _q) do
    {address, cpu, bus} = fetch16(cpu, bus)
    {cpu, Bus.write_cycle(bus, address, cpu.a), 4}
  end

  defp execute(cpu, bus, _opcode, 3, 6, 2, _p, _q) do
    {value, bus} = Bus.read_cycle(bus, 0xFF00 + cpu.c)
    {%{cpu | a: value}, bus, 2}
  end

  defp execute(cpu, bus, _opcode, 3, 7, 2, _p, _q) do
    {address, cpu, bus} = fetch16(cpu, bus)
    {value, bus} = Bus.read_cycle(bus, address)
    {%{cpu | a: value}, bus, 4}
  end

  defp execute(cpu, bus, _opcode, 3, 0, 3, _p, _q) do
    {address, cpu, bus} = fetch16(cpu, bus)
    {%{cpu | pc: address}, Bus.idle(bus, 1), 4}
  end

  defp execute(cpu, bus, _opcode, 3, 1, 3, _p, _q) do
    {cb_opcode, cpu, bus} = fetch8(cpu, bus)
    execute_cb(cpu, bus, cb_opcode)
  end

  defp execute(cpu, bus, _opcode, 3, 6, 3, _p, _q),
    do: {%{cpu | ime_state: :disabled}, bus, 1}

  defp execute(%{ime_state: :disabled} = cpu, bus, _opcode, 3, 7, 3, _p, _q),
    do: {%{cpu | ime_state: :scheduled}, bus, 1}

  defp execute(cpu, bus, _opcode, 3, 7, 3, _p, _q), do: {cpu, bus, 1}

  defp execute(cpu, bus, _opcode, 3, y, 4, _p, _q) when y < 4 do
    {address, cpu, bus} = fetch16(cpu, bus)

    if condition?(cpu, y) do
      return_address = cpu.pc
      bus = Bus.idle(bus, 1)
      {cpu, bus} = push16(cpu, bus, return_address)
      {%{cpu | pc: address}, bus, 6}
    else
      {cpu, bus, 3}
    end
  end

  defp execute(cpu, bus, _opcode, 3, _y, 5, p, 0) do
    bus = Bus.idle(bus, 1)
    {cpu, bus} = push16(cpu, bus, get_rp2(cpu, p))
    {cpu, bus, 4}
  end

  defp execute(cpu, bus, _opcode, 3, _y, 5, 0, 1) do
    {address, cpu, bus} = fetch16(cpu, bus)
    return_address = cpu.pc
    bus = Bus.idle(bus, 1)
    {cpu, bus} = push16(cpu, bus, return_address)
    {%{cpu | pc: address}, bus, 6}
  end

  defp execute(cpu, bus, _opcode, 3, y, 6, _p, _q) do
    {value, cpu, bus} = fetch8(cpu, bus)
    {alu(cpu, y, value), bus, 2}
  end

  defp execute(cpu, bus, _opcode, 3, y, 7, _p, _q) do
    bus = Bus.idle(bus, 1)
    {cpu, bus} = push16(cpu, bus, cpu.pc)
    {%{cpu | pc: y * 8}, bus, 4}
  end

  # Every remaining x=3 encoding is one of the eleven silicon lock-up opcodes.
  # This final function head avoids a membership scan on every valid opcode.
  defp execute(cpu, bus, _opcode, 3, _y, _z, _p, _q),
    do: {%{cpu | run_state: :locked}, bus, 1}

  defp execute_cb(cpu, bus, opcode) do
    x = opcode >>> 6
    y = opcode >>> 3 &&& 0x07
    z = opcode &&& 0x07
    {value, bus} = get_r(cpu, bus, z)

    case x do
      0 ->
        {result, carry} = rotate_shift(cpu, y, value)
        {cpu, bus} = put_r(%{cpu | f: flags(result == 0, false, false, carry)}, bus, z, result)
        {cpu, bus, if(z == 6, do: 4, else: 2)}

      1 ->
        zero = (value &&& 1 <<< y) == 0
        cpu = %{cpu | f: flags(zero, false, true, flag?(cpu, :c))}
        {cpu, bus, if(z == 6, do: 3, else: 2)}

      2 ->
        {cpu, bus} = put_r(cpu, bus, z, value &&& bxor(0xFF, 1 <<< y))
        {cpu, bus, if(z == 6, do: 4, else: 2)}

      3 ->
        {cpu, bus} = put_r(cpu, bus, z, value ||| 1 <<< y)
        {cpu, bus, if(z == 6, do: 4, else: 2)}
    end
  end

  defp accumulator_misc(cpu, 0) do
    carry = (cpu.a &&& 0x80) != 0
    value = band(cpu.a <<< 1, 0xFF) ||| if(carry, do: 1, else: 0)
    {%{cpu | a: value, f: flags(false, false, false, carry)}, 1}
  end

  defp accumulator_misc(cpu, 1) do
    carry = (cpu.a &&& 0x01) != 0
    value = cpu.a >>> 1 ||| if(carry, do: 0x80, else: 0)
    {%{cpu | a: value, f: flags(false, false, false, carry)}, 1}
  end

  defp accumulator_misc(cpu, 2) do
    carry = (cpu.a &&& 0x80) != 0
    value = band(cpu.a <<< 1, 0xFF) ||| if(flag?(cpu, :c), do: 1, else: 0)
    {%{cpu | a: value, f: flags(false, false, false, carry)}, 1}
  end

  defp accumulator_misc(cpu, 3) do
    carry = (cpu.a &&& 0x01) != 0
    value = cpu.a >>> 1 ||| if(flag?(cpu, :c), do: 0x80, else: 0)
    {%{cpu | a: value, f: flags(false, false, false, carry)}, 1}
  end

  defp accumulator_misc(cpu, 4), do: {daa(cpu), 1}

  defp accumulator_misc(cpu, 5) do
    f = (cpu.f ||| @flag_n ||| @flag_h) &&& 0xF0
    {%{cpu | a: bxor(cpu.a, 0xFF), f: f}, 1}
  end

  defp accumulator_misc(cpu, 6), do: {%{cpu | f: flags(flag?(cpu, :z), false, false, true)}, 1}

  defp accumulator_misc(cpu, 7),
    do: {%{cpu | f: flags(flag?(cpu, :z), false, false, not flag?(cpu, :c))}, 1}

  defp alu(cpu, 0, value), do: add_a(cpu, value, 0)
  defp alu(cpu, 1, value), do: add_a(cpu, value, if(flag?(cpu, :c), do: 1, else: 0))
  defp alu(cpu, 2, value), do: sub_a(cpu, value, 0, true)
  defp alu(cpu, 3, value), do: sub_a(cpu, value, if(flag?(cpu, :c), do: 1, else: 0), true)

  defp alu(cpu, 4, value) do
    result = cpu.a &&& value
    %{cpu | a: result, f: flags(result == 0, false, true, false)}
  end

  defp alu(cpu, 5, value) do
    result = bxor(cpu.a, value)
    %{cpu | a: result, f: flags(result == 0, false, false, false)}
  end

  defp alu(cpu, 6, value) do
    result = cpu.a ||| value
    %{cpu | a: result, f: flags(result == 0, false, false, false)}
  end

  defp alu(cpu, 7, value), do: sub_a(cpu, value, 0, false)

  defp add_a(cpu, value, carry) do
    sum = cpu.a + value + carry
    result = band(sum, 0xFF)
    f = flags(result == 0, false, (cpu.a &&& 0x0F) + (value &&& 0x0F) + carry > 0x0F, sum > 0xFF)
    %{cpu | a: result, f: f}
  end

  defp sub_a(cpu, value, carry, store?) do
    difference = cpu.a - value - carry
    result = band(difference, 0xFF)
    half = (cpu.a &&& 0x0F) < (value &&& 0x0F) + carry
    f = flags(result == 0, true, half, difference < 0)
    if store?, do: %{cpu | a: result, f: f}, else: %{cpu | f: f}
  end

  defp daa(cpu) do
    subtract? = flag?(cpu, :n)
    carry? = flag?(cpu, :c)
    half? = flag?(cpu, :h)

    {adjustment, carry?} =
      if subtract? do
        {if(carry?, do: 0x60, else: 0) + if(half?, do: 0x06, else: 0), carry?}
      else
        high_adjust? = carry? or cpu.a > 0x99

        adjustment =
          if(high_adjust?, do: 0x60, else: 0) +
            if(half? or (cpu.a &&& 0x0F) > 9, do: 0x06, else: 0)

        {adjustment, high_adjust?}
      end

    result = band(if(subtract?, do: cpu.a - adjustment, else: cpu.a + adjustment), 0xFF)
    %{cpu | a: result, f: flags(result == 0, subtract?, false, carry?)}
  end

  defp rotate_shift(_cpu, 0, value) do
    carry = (value &&& 0x80) != 0
    {band(value <<< 1, 0xFF) ||| if(carry, do: 1, else: 0), carry}
  end

  defp rotate_shift(_cpu, 1, value) do
    carry = (value &&& 0x01) != 0
    {value >>> 1 ||| if(carry, do: 0x80, else: 0), carry}
  end

  defp rotate_shift(cpu, 2, value) do
    carry = (value &&& 0x80) != 0
    {band(value <<< 1, 0xFF) ||| if(flag?(cpu, :c), do: 1, else: 0), carry}
  end

  defp rotate_shift(cpu, 3, value) do
    carry = (value &&& 0x01) != 0
    {value >>> 1 ||| if(flag?(cpu, :c), do: 0x80, else: 0), carry}
  end

  defp rotate_shift(_cpu, 4, value), do: {band(value <<< 1, 0xFF), (value &&& 0x80) != 0}
  defp rotate_shift(_cpu, 5, value), do: {value >>> 1 ||| (value &&& 0x80), (value &&& 0x01) != 0}
  defp rotate_shift(_cpu, 6, value), do: {(value <<< 4 ||| value >>> 4) &&& 0xFF, false}
  defp rotate_shift(_cpu, 7, value), do: {value >>> 1, (value &&& 0x01) != 0}

  defp get_r(cpu, bus, 0), do: {cpu.b, bus}
  defp get_r(cpu, bus, 1), do: {cpu.c, bus}
  defp get_r(cpu, bus, 2), do: {cpu.d, bus}
  defp get_r(cpu, bus, 3), do: {cpu.e, bus}
  defp get_r(cpu, bus, 4), do: {cpu.h, bus}
  defp get_r(cpu, bus, 5), do: {cpu.l, bus}
  defp get_r(cpu, bus, 6), do: Bus.read_cycle(bus, get_rp(cpu, 2))
  defp get_r(cpu, bus, 7), do: {cpu.a, bus}

  defp put_r(cpu, bus, 0, value), do: {%{cpu | b: value}, bus}
  defp put_r(cpu, bus, 1, value), do: {%{cpu | c: value}, bus}
  defp put_r(cpu, bus, 2, value), do: {%{cpu | d: value}, bus}
  defp put_r(cpu, bus, 3, value), do: {%{cpu | e: value}, bus}
  defp put_r(cpu, bus, 4, value), do: {%{cpu | h: value}, bus}
  defp put_r(cpu, bus, 5, value), do: {%{cpu | l: value}, bus}
  defp put_r(cpu, bus, 6, value), do: {cpu, Bus.write_cycle(bus, get_rp(cpu, 2), value)}
  defp put_r(cpu, bus, 7, value), do: {%{cpu | a: value}, bus}

  defp get_rp(cpu, 0), do: cpu.b * 0x100 + cpu.c
  defp get_rp(cpu, 1), do: cpu.d * 0x100 + cpu.e
  defp get_rp(cpu, 2), do: cpu.h * 0x100 + cpu.l
  defp get_rp(cpu, 3), do: cpu.sp

  defp put_rp(cpu, 0, value), do: %{cpu | b: value >>> 8, c: value &&& 0xFF}
  defp put_rp(cpu, 1, value), do: %{cpu | d: value >>> 8, e: value &&& 0xFF}
  defp put_rp(cpu, 2, value), do: %{cpu | h: value >>> 8, l: value &&& 0xFF}
  defp put_rp(cpu, 3, value), do: %{cpu | sp: value}

  defp get_rp2(cpu, 0), do: get_rp(cpu, 0)
  defp get_rp2(cpu, 1), do: get_rp(cpu, 1)
  defp get_rp2(cpu, 2), do: get_rp(cpu, 2)
  defp get_rp2(cpu, 3), do: cpu.a * 0x100 + cpu.f

  defp put_rp2(cpu, 0, value), do: put_rp(cpu, 0, value)
  defp put_rp2(cpu, 1, value), do: put_rp(cpu, 1, value)
  defp put_rp2(cpu, 2, value), do: put_rp(cpu, 2, value)
  defp put_rp2(cpu, 3, value), do: %{cpu | a: value >>> 8, f: value &&& 0xF0}

  defp indirect_address(cpu, 0), do: get_rp(cpu, 0)
  defp indirect_address(cpu, 1), do: get_rp(cpu, 1)
  defp indirect_address(cpu, 2), do: get_rp(cpu, 2)
  defp indirect_address(cpu, 3), do: get_rp(cpu, 2)

  defp advance_hl(cpu, p) when p < 2, do: cpu
  defp advance_hl(cpu, 2), do: put_rp(cpu, 2, inc16(get_rp(cpu, 2)))
  defp advance_hl(cpu, 3), do: put_rp(cpu, 2, dec16(get_rp(cpu, 2)))

  defp fetch8(%{halt_bug: true} = cpu, bus) do
    {value, bus} = Bus.read_cycle(bus, cpu.pc)
    {value, %{cpu | halt_bug: false}, bus}
  end

  defp fetch8(cpu, bus) do
    {value, bus} = Bus.read_cycle(bus, cpu.pc)
    {value, %{cpu | pc: inc16(cpu.pc)}, bus}
  end

  defp fetch16(cpu, bus) do
    {low, cpu, bus} = fetch8(cpu, bus)
    {high, cpu, bus} = fetch8(cpu, bus)
    {low + high * 0x100, cpu, bus}
  end

  defp push16(cpu, bus, value) do
    sp = dec16(cpu.sp)
    bus = Bus.write_cycle(bus, sp, value >>> 8)
    sp = dec16(sp)
    {%{cpu | sp: sp}, Bus.write_cycle(bus, sp, value &&& 0xFF)}
  end

  defp pop16(cpu, bus) do
    {low, bus} = Bus.read_cycle(bus, cpu.sp)
    sp = inc16(cpu.sp)
    {high, bus} = Bus.read_cycle(bus, sp)
    {low + high * 0x100, %{cpu | sp: inc16(sp)}, bus}
  end

  defp service_interrupt(cpu, bus, pending) do
    index = interrupt_index(pending)
    mask = 1 <<< index
    bus = bus |> Bus.acknowledge_interrupt(mask) |> Bus.idle(2)
    {cpu, bus} = push16(cpu, bus, cpu.pc)

    cpu = %{
      cpu
      | pc: elem(@interrupt_vectors, index),
        ime_state: :disabled,
        run_state: :running,
        halt_bug: false
    }

    {cpu, Bus.idle(bus, 1), 5}
  end

  defp interrupt_index(pending) when (pending &&& 0x01) != 0, do: 0
  defp interrupt_index(pending) when (pending &&& 0x02) != 0, do: 1
  defp interrupt_index(pending) when (pending &&& 0x04) != 0, do: 2
  defp interrupt_index(pending) when (pending &&& 0x08) != 0, do: 3
  defp interrupt_index(_pending), do: 4

  defp condition?(cpu, 0), do: not flag?(cpu, :z)
  defp condition?(cpu, 1), do: flag?(cpu, :z)
  defp condition?(cpu, 2), do: not flag?(cpu, :c)
  defp condition?(cpu, 3), do: flag?(cpu, :c)

  defp advance_ime(%{ime_state: :scheduled} = cpu, true), do: %{cpu | ime_state: :enabled}
  defp advance_ime(cpu, _enable?), do: cpu

  defp flags(z, n, h, c) do
    if(z, do: @flag_z, else: 0) |||
      if(n, do: @flag_n, else: 0) |||
      if(h, do: @flag_h, else: 0) |||
      if(c, do: @flag_c, else: 0)
  end

  defp add_signed(value, offset),
    do: band(value + if(offset < 0x80, do: offset, else: offset - 0x100), 0xFFFF)

  defp inc16(value), do: band(value + 1, 0xFFFF)
  defp dec16(value), do: band(value - 1, 0xFFFF)
end
