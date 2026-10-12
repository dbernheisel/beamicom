defmodule Beamicom.GBA.CPU.Thumb do
  @moduledoc false

  import Bitwise

  alias Beamicom.GBA.{Bus, CPU}
  alias Beamicom.GBA.CPU.ALU

  @mask 0xFFFF_FFFF

  @decode_table (for prefix <- 0..0x3FF do
                   instruction = prefix <<< 6

                   cond do
                     (instruction &&& 0xE000) == 0x2000 -> :immediate
                     (instruction &&& 0xE000) == 0x6000 -> :immediate_transfer
                     (instruction &&& 0xF000) == 0xD000 -> :conditional_branch
                     (instruction &&& 0xFC00) == 0x4000 -> :alu
                     (instruction &&& 0xF800) in [0x0000, 0x0800, 0x1000] -> :shift_immediate
                     (instruction &&& 0xF800) == 0x1800 -> :add_subtract
                     (instruction &&& 0xFC00) == 0x4400 -> :high_register
                     (instruction &&& 0xF800) == 0x4800 -> :pc_relative_load
                     (instruction &&& 0xF000) == 0x5000 -> :register_transfer
                     (instruction &&& 0xF000) == 0x8000 -> :halfword_transfer
                     (instruction &&& 0xF000) == 0x9000 -> :stack_relative_transfer
                     (instruction &&& 0xF000) == 0xA000 -> :load_address
                     (instruction &&& 0xFF00) == 0xB000 -> :add_stack_pointer
                     (instruction &&& 0xF600) == 0xB400 -> :push_pop
                     (instruction &&& 0xF000) == 0xC000 -> :multiple_transfer
                     (instruction &&& 0xF800) == 0xE000 -> :unconditional_branch
                     (instruction &&& 0xF800) == 0xF000 -> :long_branch_prefix
                     (instruction &&& 0xF800) == 0xF800 -> :long_branch_suffix
                     true -> :undefined
                   end
                 end)
                |> List.to_tuple()

  @compile {:inline,
            execute: 4,
            decode_kind: 1,
            execute_decoded: 5,
            register: 2,
            put_register: 3,
            put_register_and_cpsr: 4,
            put_cpsr: 2,
            thumb_operand: 3,
            branch: 2,
            bit?: 2,
            bool: 1}

  def execute(%CPU{} = cpu, %Bus{} = bus, instruction, address) do
    execute_decoded(cpu, bus, instruction, address, decode_kind(instruction))
  end

  @doc false
  def decode_kind(instruction) when instruction in 0x0000..0xFFFF,
    do: elem(@decode_table, instruction >>> 6)

  @doc false
  def execute_decoded(%CPU{} = cpu, %Bus{} = bus, instruction, address, kind) do
    case kind do
      :immediate ->
        immediate(cpu, bus, instruction)

      :immediate_transfer ->
        immediate_transfer(cpu, bus, instruction)

      :conditional_branch ->
        conditional_branch(cpu, bus, instruction, address)

      :alu ->
        alu(cpu, bus, instruction)

      :shift_immediate ->
        shift_immediate(cpu, bus, instruction)

      :add_subtract ->
        add_subtract(cpu, bus, instruction)

      :high_register ->
        high_register(cpu, bus, instruction, address)

      :pc_relative_load ->
        pc_relative_load(cpu, bus, instruction, address)

      :register_transfer ->
        register_transfer(cpu, bus, instruction)

      :halfword_transfer ->
        halfword_transfer(cpu, bus, instruction)

      :stack_relative_transfer ->
        stack_relative_transfer(cpu, bus, instruction)

      :load_address ->
        load_address(cpu, bus, instruction, address)

      :add_stack_pointer ->
        add_stack_pointer(cpu, bus, instruction)

      :push_pop ->
        push_pop(cpu, bus, instruction)

      :multiple_transfer ->
        multiple_transfer(cpu, bus, instruction)

      :unconditional_branch ->
        unconditional_branch(cpu, bus, instruction, address)

      :long_branch_prefix ->
        long_branch_prefix(cpu, bus, instruction, address)

      :long_branch_suffix ->
        long_branch_suffix(cpu, bus, instruction, address)

      :undefined ->
        {:error, {:undefined_thumb_instruction, instruction, address}, cpu, bus}
    end
  end

  defp shift_immediate(cpu, bus, instruction) do
    type = instruction >>> 11 &&& 0x3
    amount = instruction >>> 6 &&& 0x1F
    source = register(cpu, instruction >>> 3 &&& 0x7)
    destination = instruction &&& 0x7
    {result, carry} = ALU.shift_immediate(source, type, amount, ALU.carry?(cpu.cpsr))

    cpu = put_register_and_cpsr(cpu, destination, result, ALU.put_nzc(cpu.cpsr, result, carry))

    {:ok, cpu, bus, 0}
  end

  defp add_subtract(cpu, bus, instruction) do
    immediate? = bit?(instruction, 10)
    subtract? = bit?(instruction, 9)
    left = register(cpu, instruction >>> 3 &&& 0x7)
    right_index = instruction >>> 6 &&& 0x7
    right = if immediate?, do: right_index, else: register(cpu, right_index)
    destination = instruction &&& 0x7

    {result, carry, overflow} =
      if subtract?, do: ALU.subtract(left, right), else: ALU.add(left, right)

    cpu =
      put_register_and_cpsr(
        cpu,
        destination,
        result,
        ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
      )

    {:ok, cpu, bus, 0}
  end

  defp immediate(cpu, bus, instruction) do
    opcode = instruction >>> 11 &&& 0x3
    destination = instruction >>> 8 &&& 0x7
    immediate = instruction &&& 0xFF
    left = register(cpu, destination)

    case opcode do
      0 ->
        cpu =
          put_register_and_cpsr(
            cpu,
            destination,
            immediate,
            ALU.put_nz(cpu.cpsr, immediate)
          )

        {:ok, cpu, bus, 0}

      1 ->
        {result, carry, overflow} = ALU.subtract(left, immediate)
        {:ok, put_cpsr(cpu, ALU.put_nzcv(cpu.cpsr, result, carry, overflow)), bus, 0}

      2 ->
        {result, carry, overflow} = ALU.add(left, immediate)

        cpu =
          put_register_and_cpsr(
            cpu,
            destination,
            result,
            ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
          )

        {:ok, cpu, bus, 0}

      3 ->
        {result, carry, overflow} = ALU.subtract(left, immediate)

        cpu =
          put_register_and_cpsr(
            cpu,
            destination,
            result,
            ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
          )

        {:ok, cpu, bus, 0}
    end
  end

  defp alu(cpu, bus, instruction) do
    opcode = instruction >>> 6 &&& 0xF
    source = register(cpu, instruction >>> 3 &&& 0x7)
    destination = instruction &&& 0x7
    left = register(cpu, destination)
    carry = ALU.carry?(cpu.cpsr)

    case opcode do
      0 ->
        logical_result(cpu, bus, destination, left &&& source, carry)

      1 ->
        logical_result(cpu, bus, destination, bxor(left, source), carry)

      2 ->
        shifted_result(cpu, bus, destination, left, 0, source &&& 0xFF)

      3 ->
        shifted_result(cpu, bus, destination, left, 1, source &&& 0xFF)

      4 ->
        shifted_result(cpu, bus, destination, left, 2, source &&& 0xFF)

      5 ->
        arithmetic_result(cpu, bus, destination, ALU.add(left, source, bool(carry)))

      6 ->
        arithmetic_result(cpu, bus, destination, ALU.subtract(left, source, bool(not carry)))

      7 ->
        shifted_result(cpu, bus, destination, left, 3, source &&& 0xFF)

      8 ->
        test_result(cpu, bus, left &&& source, carry)

      9 ->
        arithmetic_result(cpu, bus, destination, ALU.subtract(0, source))

      10 ->
        compare_result(cpu, bus, ALU.subtract(left, source))

      11 ->
        compare_result(cpu, bus, ALU.add(left, source))

      12 ->
        logical_result(cpu, bus, destination, left ||| source, carry)

      13 ->
        logical_result(cpu, Bus.idle(bus, 1), destination, left * source &&& @mask, carry, 1)

      14 ->
        logical_result(cpu, bus, destination, left &&& bnot(source), carry)

      15 ->
        logical_result(cpu, bus, destination, bnot(source) &&& @mask, carry)
    end
  end

  defp logical_result(cpu, bus, destination, result, carry, cycles \\ 0) do
    cpu = put_register_and_cpsr(cpu, destination, result, ALU.put_nzc(cpu.cpsr, result, carry))

    {:ok, cpu, bus, cycles}
  end

  defp test_result(cpu, bus, result, carry),
    do: {:ok, put_cpsr(cpu, ALU.put_nzc(cpu.cpsr, result, carry)), bus, 0}

  defp arithmetic_result(cpu, bus, destination, {result, carry, overflow}) do
    cpu =
      put_register_and_cpsr(
        cpu,
        destination,
        result,
        ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
      )

    {:ok, cpu, bus, 0}
  end

  defp compare_result(cpu, bus, {result, carry, overflow}),
    do: {:ok, put_cpsr(cpu, ALU.put_nzcv(cpu.cpsr, result, carry, overflow)), bus, 0}

  defp shifted_result(cpu, bus, destination, value, type, amount) do
    {result, carry} = ALU.shift_register(value, type, amount, ALU.carry?(cpu.cpsr))
    logical_result(cpu, Bus.idle(bus, 1), destination, result, carry, 1)
  end

  defp high_register(cpu, bus, instruction, address) do
    opcode = instruction >>> 8 &&& 0x3
    source_index = instruction >>> 3 &&& 0xF
    destination = (instruction &&& 0x7) + (instruction >>> 4 &&& 0x8)
    source = thumb_operand(cpu, source_index, address)
    left = thumb_operand(cpu, destination, address)

    case opcode do
      0 ->
        result = left + source &&& @mask

        cpu =
          if destination == 15,
            do: branch(cpu, result),
            else: put_register(cpu, destination, result)

        {:ok, cpu, bus, 0}

      1 ->
        compare_result(cpu, bus, ALU.subtract(left, source))

      2 ->
        cpu =
          if destination == 15,
            do: branch(cpu, source),
            else: put_register(cpu, destination, source)

        {:ok, cpu, bus, 0}

      3 ->
        {:ok, CPU.exchange(cpu, source), bus, 0}
    end
  end

  defp pc_relative_load(cpu, bus, instruction, address) do
    destination = instruction >>> 8 &&& 0x7
    load_address = (address + 4 &&& 0xFFFF_FFFC) + (instruction &&& 0xFF) * 4
    {value, bus, cycles} = Bus.read32(bus, load_address)
    {:ok, put_register(cpu, destination, value), bus, cycles}
  end

  defp register_transfer(cpu, bus, instruction) do
    opcode = instruction >>> 9 &&& 0x7
    offset = register(cpu, instruction >>> 6 &&& 0x7)
    base = register(cpu, instruction >>> 3 &&& 0x7)
    destination = instruction &&& 0x7
    address = base + offset &&& @mask

    case opcode do
      0 -> store32(cpu, bus, destination, address)
      1 -> store16(cpu, bus, destination, address)
      2 -> store8(cpu, bus, destination, address)
      3 -> load_signed8(cpu, bus, destination, address)
      4 -> load32(cpu, bus, destination, address)
      5 -> load16(cpu, bus, destination, address)
      6 -> load8(cpu, bus, destination, address)
      7 -> load_signed16(cpu, bus, destination, address)
    end
  end

  defp immediate_transfer(cpu, bus, instruction) do
    byte? = bit?(instruction, 12)
    load? = bit?(instruction, 11)
    offset = instruction >>> 6 &&& 0x1F
    base = register(cpu, instruction >>> 3 &&& 0x7)
    destination = instruction &&& 0x7
    address = base + if(byte?, do: offset, else: offset * 4) &&& @mask

    case {load?, byte?} do
      {false, false} -> store32(cpu, bus, destination, address)
      {true, false} -> load32(cpu, bus, destination, address)
      {false, true} -> store8(cpu, bus, destination, address)
      {true, true} -> load8(cpu, bus, destination, address)
    end
  end

  defp halfword_transfer(cpu, bus, instruction) do
    load? = bit?(instruction, 11)
    offset = (instruction >>> 6 &&& 0x1F) * 2
    base = register(cpu, instruction >>> 3 &&& 0x7)
    destination = instruction &&& 0x7
    address = base + offset &&& @mask

    if load?,
      do: load16(cpu, bus, destination, address),
      else: store16(cpu, bus, destination, address)
  end

  defp stack_relative_transfer(cpu, bus, instruction) do
    load? = bit?(instruction, 11)
    destination = instruction >>> 8 &&& 0x7
    address = register(cpu, 13) + (instruction &&& 0xFF) * 4 &&& @mask

    if load?,
      do: load32(cpu, bus, destination, address),
      else: store32(cpu, bus, destination, address)
  end

  defp load_address(cpu, bus, instruction, address) do
    use_sp? = bit?(instruction, 11)
    destination = instruction >>> 8 &&& 0x7
    base = if use_sp?, do: register(cpu, 13), else: address + 4 &&& 0xFFFF_FFFC
    value = base + (instruction &&& 0xFF) * 4 &&& @mask
    {:ok, put_register(cpu, destination, value), bus, 0}
  end

  defp add_stack_pointer(cpu, bus, instruction) do
    offset = (instruction &&& 0x7F) * 4
    offset = if bit?(instruction, 7), do: -offset, else: offset
    {:ok, put_register(cpu, 13, register(cpu, 13) + offset), bus, 0}
  end

  defp push_pop(cpu, bus, instruction) do
    pop? = bit?(instruction, 11)
    extra? = bit?(instruction, 8)
    low_registers = for register <- 0..7, bit?(instruction, register), do: register

    registers =
      cond do
        pop? and extra? -> low_registers ++ [15]
        not pop? and extra? -> low_registers ++ [14]
        true -> low_registers
      end

    if registers == [] do
      {:error, {:empty_register_list, instruction}, cpu, bus}
    else
      if pop?, do: pop(cpu, bus, registers), else: push(cpu, bus, registers)
    end
  end

  defp push(cpu, bus, registers) do
    stack_pointer = register(cpu, 13) - length(registers) * 4 &&& @mask

    {bus, cycles} =
      Enum.reduce(Enum.with_index(registers), {bus, 0}, fn {register, index}, {bus, cycles} ->
        {bus, access_cycles} =
          Bus.write32(bus, stack_pointer + index * 4, register(cpu, register), access(index))

        {bus, cycles + access_cycles}
      end)

    {:ok, put_register(cpu, 13, stack_pointer), bus, cycles}
  end

  defp pop(cpu, bus, registers) do
    stack_pointer = register(cpu, 13)

    {cpu, bus, cycles} =
      Enum.reduce(Enum.with_index(registers), {cpu, bus, 0}, fn {register, index},
                                                                {cpu, bus, cycles} ->
        {value, bus, access_cycles} = Bus.read32(bus, stack_pointer + index * 4, access(index))

        cpu =
          if register == 15,
            do: CPU.exchange(cpu, value),
            else: put_register(cpu, register, value)

        {cpu, bus, cycles + access_cycles}
      end)

    {:ok, put_register(cpu, 13, stack_pointer + length(registers) * 4), bus, cycles}
  end

  defp multiple_transfer(cpu, bus, instruction) do
    load? = bit?(instruction, 11)
    base_register = instruction >>> 8 &&& 0x7
    registers = for register <- 0..7, bit?(instruction, register), do: register

    if registers == [] do
      {:error, {:empty_register_list, instruction}, cpu, bus}
    else
      base = register(cpu, base_register)

      {cpu, bus, cycles} =
        Enum.reduce(Enum.with_index(registers), {cpu, bus, 0}, fn {register, index},
                                                                  {cpu, bus, cycles} ->
          address = base + index * 4

          if load? do
            {value, bus, access_cycles} = Bus.read32(bus, address, access(index))
            {put_register(cpu, register, value), bus, cycles + access_cycles}
          else
            {bus, access_cycles} =
              Bus.write32(bus, address, register(cpu, register), access(index))

            {cpu, bus, cycles + access_cycles}
          end
        end)

      cpu = put_register(cpu, base_register, base + length(registers) * 4)
      {:ok, cpu, bus, cycles}
    end
  end

  defp conditional_branch(cpu, bus, instruction, address) do
    condition = instruction >>> 8 &&& 0xF

    cond do
      condition == 0xF ->
        CPU.software_interrupt(cpu, bus, instruction &&& 0xFF)

      condition == 0xE ->
        {:error, {:undefined_thumb_instruction, instruction, address}, cpu, bus}

      ALU.condition_passed?(condition, cpu.cpsr) ->
        offset = instruction |> band(0xFF) |> bsl(1) |> ALU.sign_extend(9)
        target = address + 4 + offset
        cpu = cpu |> branch(target) |> CPU.mark_thumb_loop(bus, target, address)
        {:ok, cpu, bus, 0}

      true ->
        {:ok, cpu, bus, 0}
    end
  end

  defp unconditional_branch(cpu, bus, instruction, address) do
    offset = instruction |> band(0x7FF) |> bsl(1) |> ALU.sign_extend(12)
    {:ok, branch(cpu, address + 4 + offset), bus, 0}
  end

  defp long_branch_prefix(cpu, bus, instruction, address) do
    offset = instruction |> band(0x7FF) |> bsl(12) |> ALU.sign_extend(23)
    {:ok, put_register(cpu, 14, address + 4 + offset), bus, 0}
  end

  defp long_branch_suffix(cpu, bus, instruction, address) do
    target = register(cpu, 14) + ((instruction &&& 0x7FF) <<< 1)

    cpu =
      cpu
      |> put_register(14, address + 2 ||| 1)
      |> branch(target)

    {:ok, cpu, bus, 0}
  end

  defp load8(cpu, bus, destination, address) do
    {value, bus, cycles} = Bus.read8(bus, address)
    {:ok, put_register(cpu, destination, value), bus, cycles}
  end

  defp load16(cpu, bus, destination, address) do
    {value, bus, cycles} = Bus.read16(bus, address)
    {:ok, put_register(cpu, destination, value), bus, cycles}
  end

  defp load32(cpu, bus, destination, address) do
    {value, bus, cycles} = Bus.read32(bus, address)
    {:ok, put_register(cpu, destination, value), bus, cycles}
  end

  defp load_signed8(cpu, bus, destination, address) do
    {value, bus, cycles} = Bus.read8(bus, address)
    {:ok, put_register(cpu, destination, ALU.sign_extend(value, 8)), bus, cycles}
  end

  defp load_signed16(cpu, bus, destination, address) do
    {value, bus, cycles} = Bus.read16(bus, address)
    {:ok, put_register(cpu, destination, ALU.sign_extend(value, 16)), bus, cycles}
  end

  defp store8(cpu, bus, source, address) do
    {bus, cycles} = Bus.write8(bus, address, register(cpu, source) &&& 0xFF)
    {:ok, cpu, bus, cycles}
  end

  defp store16(cpu, bus, source, address) do
    {bus, cycles} = Bus.write16(bus, address, register(cpu, source) &&& 0xFFFF)
    {:ok, cpu, bus, cycles}
  end

  defp store32(cpu, bus, source, address) do
    {bus, cycles} = Bus.write32(bus, address, register(cpu, source))
    {:ok, cpu, bus, cycles}
  end

  defp register(%CPU{pc: pc}, 15), do: pc
  defp register(%CPU{registers: registers}, index), do: elem(registers, index)

  defp put_register(%CPU{} = cpu, 15, value), do: %{cpu | pc: value &&& @mask}

  defp put_register(%CPU{} = cpu, index, value),
    do: %{cpu | registers: put_elem(cpu.registers, index, value &&& @mask)}

  defp put_register_and_cpsr(%CPU{} = cpu, index, value, cpsr) do
    %{
      cpu
      | registers: put_elem(cpu.registers, index, value &&& @mask),
        cpsr: cpsr &&& @mask
    }
  end

  defp put_cpsr(%CPU{} = cpu, value), do: %{cpu | cpsr: value &&& @mask}

  defp thumb_operand(_cpu, 15, instruction_address), do: instruction_address + 4
  defp thumb_operand(cpu, index, _instruction_address), do: register(cpu, index)

  defp branch(%CPU{} = cpu, target) do
    %{cpu | pc: target &&& 0xFFFF_FFFE, next_fetch: :nonsequential}
  end

  defp access(0), do: :nonsequential
  defp access(_index), do: :sequential

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
