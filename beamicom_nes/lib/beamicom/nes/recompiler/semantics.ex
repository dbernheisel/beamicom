defmodule Beamicom.NES.Recompiler.Semantics do
  @moduledoc false

  import Bitwise

  @c 0x01
  @z 0x02
  @i 0x04
  @d 0x08
  @v 0x40
  @n 0x80

  @immediate [:LDA, :LDX, :LDY, :ADC, :SBC, :CMP, :CPX, :CPY, :AND, :ORA, :EOR]
  @implied [
    :CLC,
    :SEC,
    :CLI,
    :SEI,
    :CLD,
    :SED,
    :CLV,
    :INX,
    :INY,
    :DEX,
    :DEY,
    :TAX,
    :TAY,
    :TXA,
    :TYA,
    :TSX,
    :TXS,
    :NOP
  ]
  @branches [:BCC, :BCS, :BNE, :BEQ, :BPL, :BMI, :BVC, :BVS]

  @doc false
  def lowered?(operation, :zp, _cycles), do: operation in [:STA, :LDA, :LDX, :ADC, :INC, :DEC]
  def lowered?(operation, :zpx, _cycles), do: operation in [:LDA, :STA]

  def lowered?(operation, :abs, _cycles),
    do: operation in [:LDA, :LDX, :LDY, :STA, :STX, :STY, :JMP, :JSR]

  def lowered?(:LDA, mode, _cycles) when mode in [:abx, :aby, :izy], do: true
  def lowered?(:STA, mode, _cycles) when mode in [:abx, :aby], do: true
  def lowered?(operation, :imm, 2), do: operation in @immediate
  def lowered?(operation, :imp, 2), do: operation in @implied
  def lowered?(:RTS, :imp, 6), do: true
  def lowered?(operation, :acc, 2), do: operation in [:ASL, :LSR, :ROL, :ROR]
  def lowered?(operation, :rel, 2), do: operation in @branches
  def lowered?(_operation, _mode, _cycles), do: false

  @doc false
  def coverage(%{instructions: instructions} = discovery) do
    lowered_identities =
      Enum.count(instructions, fn {_identity, instruction} ->
        lowered?(instruction.operation, instruction.mode, instruction.base_cycles)
      end)

    identity_count = map_size(instructions)

    %{
      lowered_instruction_identities: lowered_identities,
      instruction_identities: identity_count,
      identity_percent: percent(lowered_identities, identity_count)
    }
    |> profile_coverage(discovery)
  end

  defmacro step(cpu, bus, operation, mode, cycles, operand) do
    emit(operation, mode, cycles, operand, cpu, bus)
  end

  defp emit(operation, :zp, cycles, operand, cpu, bus)
       when operation in [:STA, :LDA, :LDX, :ADC, :INC, :DEC] do
    quote do
      {cpu, bus, poll} =
        Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 2, unquote(cycles), 0)

      {cpu, bus} =
        unquote(emit_zero_page_operation(operation, operand, quote(do: cpu), quote(do: bus)))

      Beamicom.NES.CPU.aot_complete(
        cpu,
        bus,
        unquote(cycles),
        0,
        0,
        unquote(operand),
        poll
      )
    end
  end

  defp emit(operation, :zpx, cycles, operand, cpu, bus) when operation in [:LDA, :STA] do
    quote do
      address = unquote(operand) + unquote(cpu).x &&& 0xFF

      {cpu, bus, poll} =
        Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 2, unquote(cycles), 0)

      {cpu, bus} =
        unquote(
          emit_zero_page_operation(operation, quote(do: address), quote(do: cpu), quote(do: bus))
        )

      Beamicom.NES.CPU.aot_complete(cpu, bus, unquote(cycles), 0, 0, address, poll)
    end
  end

  defp emit(operation, :abs, cycles, operand, cpu, bus)
       when operation in [:LDA, :LDX, :LDY, :STA, :STX, :STY] do
    quote do
      {cpu, bus, poll} =
        Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 3, unquote(cycles), 0)

      {cpu, bus} =
        unquote(emit_absolute_operation(operation, operand, quote(do: cpu), quote(do: bus)))

      Beamicom.NES.CPU.aot_complete(
        cpu,
        bus,
        unquote(cycles),
        0,
        0,
        unquote(operand),
        poll
      )
    end
  end

  defp emit(:LDA, mode, 4, operand, cpu, bus) when mode in [:abx, :aby] do
    index = if mode == :abx, do: quote(do: unquote(cpu).x), else: quote(do: unquote(cpu).y)

    quote do
      address = unquote(operand) + unquote(index) &&& 0xFFFF
      penalty = if (unquote(operand) &&& 0xFF00) != (address &&& 0xFF00), do: 1, else: 0
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 3, 4, penalty)
      {value, bus} = Beamicom.NES.Bus.read(bus, address)
      cpu = unquote(load_ast(quote(do: cpu), :a, quote(do: value)))
      Beamicom.NES.CPU.aot_complete(cpu, bus, 4, penalty, 0, address, poll)
    end
  end

  defp emit(:STA, mode, 5, operand, cpu, bus) when mode in [:abx, :aby] do
    index = if mode == :abx, do: quote(do: unquote(cpu).x), else: quote(do: unquote(cpu).y)

    quote do
      address = unquote(operand) + unquote(index) &&& 0xFFFF
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 3, 5, 0)
      bus = Beamicom.NES.Bus.write(bus, address, cpu.a)
      Beamicom.NES.CPU.aot_complete(cpu, bus, 5, 0, 0, address, poll)
    end
  end

  defp emit(:LDA, :izy, 5, operand, cpu, bus) do
    quote do
      base =
        unquote(ram_read_ast(bus, operand)) |||
          unquote(ram_read_ast(bus, operand + 1 &&& 0xFF)) <<< 8

      address = base + unquote(cpu).y &&& 0xFFFF
      penalty = if (base &&& 0xFF00) != (address &&& 0xFF00), do: 1, else: 0
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 2, 5, penalty)
      {value, bus} = Beamicom.NES.Bus.read(bus, address)
      cpu = unquote(load_ast(quote(do: cpu), :a, quote(do: value)))
      Beamicom.NES.CPU.aot_complete(cpu, bus, 5, penalty, 0, address, poll)
    end
  end

  defp emit(operation, :imm, 2, operand, cpu, bus) when operation in @immediate do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 2, 2, 0)
      cpu = unquote(immediate_ast(operation, quote(do: cpu), operand))
      Beamicom.NES.CPU.aot_complete(cpu, bus, 2, 0, 0, nil, poll)
    end
  end

  defp emit(operation, :imp, 2, _operand, cpu, bus) when operation in @implied do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 1, 2, 0)
      cpu = unquote(implied_ast(operation, quote(do: cpu)))
      Beamicom.NES.CPU.aot_complete(cpu, bus, 2, 0, 0, nil, poll)
    end
  end

  defp emit(operation, :acc, 2, _operand, cpu, bus)
       when operation in [:ASL, :LSR, :ROL, :ROR] do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 1, 2, 0)
      {p, value} = unquote(shift_ast(operation, quote(do: cpu.p), quote(do: cpu.a)))
      cpu = %{cpu | a: value, p: unquote(set_zn_ast(quote(do: p), quote(do: value)))}
      Beamicom.NES.CPU.aot_complete(cpu, bus, 2, 0, 0, nil, poll)
    end
  end

  defp emit(:JMP, :abs, 3, operand, cpu, bus) do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 3, 3, 0)

      Beamicom.NES.CPU.aot_complete(
        %{cpu | pc: unquote(operand)},
        bus,
        3,
        0,
        0,
        unquote(operand),
        poll
      )
    end
  end

  defp emit(:JSR, :abs, 6, operand, cpu, bus) do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 3, 6, 0)
      return = cpu.pc - 1 &&& 0xFFFF

      bus =
        unquote(
          ram_write_ast(quote(do: bus), quote(do: 0x0100 + cpu.sp), quote(do: return >>> 8))
        )

      cpu = %{cpu | sp: cpu.sp - 1 &&& 0xFF}

      bus =
        unquote(
          ram_write_ast(quote(do: bus), quote(do: 0x0100 + cpu.sp), quote(do: return &&& 0xFF))
        )

      cpu = %{cpu | sp: cpu.sp - 1 &&& 0xFF, pc: unquote(operand)}
      Beamicom.NES.CPU.aot_complete(cpu, bus, 6, 0, 0, unquote(operand), poll)
    end
  end

  defp emit(:RTS, :imp, 6, _operand, cpu, bus) do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 1, 6, 0)
      low_sp = cpu.sp + 1 &&& 0xFF
      low = unquote(ram_read_ast(quote(do: bus), quote(do: 0x0100 + low_sp)))
      high_sp = low_sp + 1 &&& 0xFF
      high = unquote(ram_read_ast(quote(do: bus), quote(do: 0x0100 + high_sp)))
      cpu = %{cpu | sp: high_sp, pc: (low ||| high <<< 8) + 1 &&& 0xFFFF}
      Beamicom.NES.CPU.aot_complete(cpu, bus, 6, 0, 0, nil, poll)
    end
  end

  defp emit(operation, :rel, 2, operand, cpu, bus) when operation in @branches do
    quote do
      {cpu, bus, poll} = Beamicom.NES.CPU.aot_prepare(unquote(cpu), unquote(bus), 2, 2, 0)
      offset = if unquote(operand) >= 0x80, do: unquote(operand) - 0x100, else: unquote(operand)
      target = cpu.pc + offset &&& 0xFFFF
      taken = unquote(branch_ast(operation, quote(do: cpu.p)))

      extra =
        if taken, do: if((cpu.pc &&& 0xFF00) != (target &&& 0xFF00), do: 2, else: 1), else: 0

      cpu = if taken, do: %{cpu | pc: target}, else: cpu
      Beamicom.NES.CPU.aot_complete(cpu, bus, 2, 0, extra, target, poll)
    end
  end

  defp emit(_operation, _mode, _cycles, _operand, cpu, bus) do
    quote do
      Beamicom.NES.CPU.step(unquote(cpu), unquote(bus))
    end
  end

  defp emit_zero_page_operation(:STA, address, cpu, bus),
    do: quote(do: {unquote(cpu), unquote(ram_write_ast(bus, address, quote(do: unquote(cpu).a)))})

  defp emit_zero_page_operation(operation, address, cpu, bus) when operation in [:LDA, :LDX] do
    register = if operation == :LDA, do: :a, else: :x
    quote(do: {unquote(load_ast(cpu, register, ram_read_ast(bus, address))), unquote(bus)})
  end

  defp emit_zero_page_operation(:ADC, address, cpu, bus),
    do: quote(do: {unquote(adc_ast(cpu, ram_read_ast(bus, address))), unquote(bus)})

  defp emit_zero_page_operation(operation, address, cpu, bus) when operation in [:INC, :DEC] do
    delta = if operation == :INC, do: 1, else: -1

    quote do
      value = unquote(ram_read_ast(bus, address)) + unquote(delta) &&& 0xFF
      cpu = %{unquote(cpu) | p: unquote(set_zn_ast(quote(do: unquote(cpu).p), quote(do: value)))}
      {cpu, unquote(ram_write_ast(bus, address, quote(do: value)))}
    end
  end

  defp emit_absolute_operation(operation, address, cpu, bus)
       when operation in [:LDA, :LDX, :LDY] do
    register = %{LDA: :a, LDX: :x, LDY: :y}[operation]

    quote do
      {value, bus} = Beamicom.NES.Bus.read(unquote(bus), unquote(address))
      {unquote(load_ast(cpu, register, quote(do: value))), bus}
    end
  end

  defp emit_absolute_operation(operation, address, cpu, bus)
       when operation in [:STA, :STX, :STY] do
    register = %{STA: :a, STX: :x, STY: :y}[operation]

    quote(
      do:
        {unquote(cpu),
         Beamicom.NES.Bus.write(unquote(bus), unquote(address), unquote(cpu).unquote(register))}
    )
  end

  defp immediate_ast(:LDA, cpu, operand), do: load_ast(cpu, :a, operand)
  defp immediate_ast(:LDX, cpu, operand), do: load_ast(cpu, :x, operand)
  defp immediate_ast(:LDY, cpu, operand), do: load_ast(cpu, :y, operand)
  defp immediate_ast(:ADC, cpu, operand), do: adc_ast(cpu, operand)

  defp immediate_ast(:SBC, cpu, operand),
    do: adc_ast(cpu, quote(do: bxor(unquote(operand), 0xFF)))

  defp immediate_ast(:CMP, cpu, operand), do: compare_ast(cpu, quote(do: unquote(cpu).a), operand)
  defp immediate_ast(:CPX, cpu, operand), do: compare_ast(cpu, quote(do: unquote(cpu).x), operand)
  defp immediate_ast(:CPY, cpu, operand), do: compare_ast(cpu, quote(do: unquote(cpu).y), operand)

  defp immediate_ast(:AND, cpu, operand),
    do: load_ast(cpu, :a, quote(do: unquote(cpu).a &&& unquote(operand)))

  defp immediate_ast(:ORA, cpu, operand),
    do: load_ast(cpu, :a, quote(do: unquote(cpu).a ||| unquote(operand)))

  defp immediate_ast(:EOR, cpu, operand),
    do: load_ast(cpu, :a, quote(do: bxor(unquote(cpu).a, unquote(operand))))

  defp implied_ast(:CLC, cpu), do: flag_cpu_ast(cpu, @c, false)
  defp implied_ast(:SEC, cpu), do: flag_cpu_ast(cpu, @c, true)
  defp implied_ast(:CLI, cpu), do: flag_cpu_ast(cpu, @i, false)
  defp implied_ast(:SEI, cpu), do: flag_cpu_ast(cpu, @i, true)
  defp implied_ast(:CLD, cpu), do: flag_cpu_ast(cpu, @d, false)
  defp implied_ast(:SED, cpu), do: flag_cpu_ast(cpu, @d, true)
  defp implied_ast(:CLV, cpu), do: flag_cpu_ast(cpu, @v, false)
  defp implied_ast(:INX, cpu), do: load_ast(cpu, :x, quote(do: unquote(cpu).x + 1))
  defp implied_ast(:INY, cpu), do: load_ast(cpu, :y, quote(do: unquote(cpu).y + 1))
  defp implied_ast(:DEX, cpu), do: load_ast(cpu, :x, quote(do: unquote(cpu).x - 1))
  defp implied_ast(:DEY, cpu), do: load_ast(cpu, :y, quote(do: unquote(cpu).y - 1))
  defp implied_ast(:TAX, cpu), do: load_ast(cpu, :x, quote(do: unquote(cpu).a))
  defp implied_ast(:TAY, cpu), do: load_ast(cpu, :y, quote(do: unquote(cpu).a))
  defp implied_ast(:TXA, cpu), do: load_ast(cpu, :a, quote(do: unquote(cpu).x))
  defp implied_ast(:TYA, cpu), do: load_ast(cpu, :a, quote(do: unquote(cpu).y))
  defp implied_ast(:TSX, cpu), do: load_ast(cpu, :x, quote(do: unquote(cpu).sp))
  defp implied_ast(:TXS, cpu), do: quote(do: %{unquote(cpu) | sp: unquote(cpu).x})
  defp implied_ast(:NOP, cpu), do: cpu

  defp load_ast(cpu, register, value) do
    quote do
      value = unquote(value) &&& 0xFF

      %{
        unquote(cpu)
        | unquote(register) => value,
          p: unquote(set_zn_ast(quote(do: unquote(cpu).p), quote(do: value)))
      }
    end
  end

  defp adc_ast(cpu, operand) do
    quote do
      operand = unquote(operand)
      sum = unquote(cpu).a + operand + (unquote(cpu).p &&& unquote(@c))
      result = sum &&& 0xFF
      overflow = (bxor(unquote(cpu).a, result) &&& bxor(operand, result) &&& 0x80) != 0
      p = unquote(set_zn_ast(quote(do: unquote(cpu).p), quote(do: result)))
      p = unquote(set_flag_ast(quote(do: p), @c, quote(do: sum > 0xFF)))
      p = unquote(set_flag_ast(quote(do: p), @v, quote(do: overflow)))
      %{unquote(cpu) | a: result, p: p}
    end
  end

  defp compare_ast(cpu, register, operand) do
    quote do
      operand = unquote(operand)
      difference = unquote(register) - operand
      p = unquote(set_zn_ast(quote(do: unquote(cpu).p), quote(do: difference &&& 0xFF)))
      p = unquote(set_flag_ast(quote(do: p), @c, quote(do: unquote(register) >= operand)))
      %{unquote(cpu) | p: p}
    end
  end

  defp flag_cpu_ast(cpu, mask, on),
    do: quote(do: %{unquote(cpu) | p: unquote(set_flag_ast(quote(do: unquote(cpu).p), mask, on))})

  defp set_zn_ast(p, value) do
    quote do
      p = unquote(set_flag_ast(p, @z, quote(do: (unquote(value) &&& 0xFF) == 0)))
      unquote(set_flag_ast(quote(do: p), @n, quote(do: (unquote(value) &&& 0x80) != 0)))
    end
  end

  defp set_flag_ast(p, mask, condition) do
    quote do
      if unquote(condition),
        do: unquote(p) ||| unquote(mask),
        else: unquote(p) &&& unquote(bxor(0xFF, mask))
    end
  end

  defp shift_ast(:ASL, p, value),
    do:
      quote(
        do:
          {unquote(set_flag_ast(p, @c, quote(do: (unquote(value) &&& 0x80) != 0))),
           unquote(value) <<< 1 &&& 0xFF}
      )

  defp shift_ast(:LSR, p, value),
    do:
      quote(
        do:
          {unquote(set_flag_ast(p, @c, quote(do: (unquote(value) &&& 0x01) != 0))),
           unquote(value) >>> 1}
      )

  defp shift_ast(:ROL, p, value),
    do:
      quote(
        do:
          {unquote(set_flag_ast(p, @c, quote(do: (unquote(value) &&& 0x80) != 0))),
           (unquote(value) <<< 1 ||| (unquote(p) &&& unquote(@c))) &&& 0xFF}
      )

  defp shift_ast(:ROR, p, value),
    do:
      quote(
        do:
          {unquote(set_flag_ast(p, @c, quote(do: (unquote(value) &&& 0x01) != 0))),
           unquote(value) >>> 1 ||| (unquote(p) &&& unquote(@c)) <<< 7}
      )

  defp branch_ast(:BCC, p), do: quote(do: (unquote(p) &&& unquote(@c)) == 0)
  defp branch_ast(:BCS, p), do: quote(do: (unquote(p) &&& unquote(@c)) != 0)
  defp branch_ast(:BNE, p), do: quote(do: (unquote(p) &&& unquote(@z)) == 0)
  defp branch_ast(:BEQ, p), do: quote(do: (unquote(p) &&& unquote(@z)) != 0)
  defp branch_ast(:BPL, p), do: quote(do: (unquote(p) &&& unquote(@n)) == 0)
  defp branch_ast(:BMI, p), do: quote(do: (unquote(p) &&& unquote(@n)) != 0)
  defp branch_ast(:BVC, p), do: quote(do: (unquote(p) &&& unquote(@v)) == 0)
  defp branch_ast(:BVS, p), do: quote(do: (unquote(p) &&& unquote(@v)) != 0)

  defp ram_read_ast(bus, address) do
    quote do
      case unquote(bus).ram do
        {:atomics, ram} -> :atomics.get(ram, (unquote(address) &&& 0x07FF) + 1)
        ram -> :binary.at(ram, unquote(address) &&& 0x07FF)
      end
    end
  end

  defp ram_write_ast(bus, address, value) do
    quote do
      case unquote(bus).ram do
        {:atomics, ram} ->
          :atomics.put(ram, (unquote(address) &&& 0x07FF) + 1, unquote(value) &&& 0xFF)
          unquote(bus)

        _ram ->
          Beamicom.NES.Bus.write(unquote(bus), unquote(address), unquote(value))
      end
    end
  end

  defp profile_coverage(result, %{profile: %{hits: hits}, instructions: instructions}) do
    {lowered, total} =
      Enum.reduce(hits, {0, 0}, fn {identity, hit_count}, {lowered, total} ->
        instruction = Map.fetch!(instructions, identity)

        direct =
          lowered?(instruction.operation, instruction.mode, instruction.base_cycles)

        {lowered + if(direct, do: hit_count, else: 0), total + hit_count}
      end)

    Map.merge(result, %{
      lowered_profile_hits: lowered,
      profile_hits: total,
      profile_hit_percent: percent(lowered, total)
    })
  end

  defp profile_coverage(result, _discovery), do: result

  defp percent(_part, 0), do: 0.0
  defp percent(part, total), do: part * 100.0 / total
end
