defmodule Beamicom.GBA.CPU.ARM do
  @moduledoc false

  import Bitwise

  alias Beamicom.GBA.{Bus, CPU}
  alias Beamicom.GBA.CPU.ALU

  @mask 0xFFFF_FFFF

  def execute(%CPU{} = cpu, %Bus{} = bus, instruction, address) do
    execute_decoded(cpu, bus, instruction, address, decode_kind(instruction))
  end

  @doc false
  def decode_kind(instruction) when instruction in 0x0000_0000..0xFFFF_FFFF do
    case instruction &&& 0x0C00_0000 do
      0x0000_0000 ->
        decode_data_kind(instruction)

      0x0400_0000 ->
        :single_transfer

      0x0800_0000 ->
        if((instruction &&& 0x0200_0000) == 0, do: :block_transfer, else: :branch)

      0x0C00_0000 ->
        if((instruction &&& 0x0F00_0000) == 0x0F00_0000,
          do: :software_interrupt,
          else: :undefined
        )
    end
  end

  defp decode_data_kind(instruction) do
    cond do
      (instruction &&& 0x0FFF_FFF0) == 0x012F_FF10 -> :branch_exchange
      (instruction &&& 0x0FB0_0FF0) == 0x0100_0090 -> :swap
      (instruction &&& 0x0F80_00F0) == 0x0080_0090 -> :long_multiply
      (instruction &&& 0x0FC0_00F0) == 0x0000_0090 -> :multiply
      psr_transfer?(instruction) -> :psr_transfer
      (instruction &&& 0x0E00_0090) == 0x0000_0090 -> :halfword_transfer
      true -> :data_processing
    end
  end

  @doc false
  def execute_decoded(%CPU{} = cpu, %Bus{} = bus, instruction, address, kind) do
    condition = instruction >>> 28

    cond do
      condition == 0xF ->
        {:error, {:undefined_arm_instruction, instruction, address}, cpu, bus}

      ALU.condition_passed?(condition, cpu.cpsr) ->
        dispatch(cpu, bus, instruction, address, kind)

      true ->
        {:ok, cpu, bus, 0}
    end
  end

  defp dispatch(cpu, bus, instruction, address, kind) do
    case kind do
      :branch_exchange ->
        branch_exchange(cpu, bus, instruction, address)

      :swap ->
        {:error, {:unimplemented_swap, instruction, address}, cpu, bus}

      :long_multiply ->
        long_multiply(cpu, bus, instruction)

      :multiply ->
        multiply(cpu, bus, instruction)

      :psr_transfer ->
        psr_transfer(cpu, bus, instruction, address)

      :halfword_transfer ->
        halfword_transfer(cpu, bus, instruction, address)

      :branch ->
        branch(cpu, bus, instruction, address)

      :block_transfer ->
        block_transfer(cpu, bus, instruction, address)

      :single_transfer ->
        single_transfer(cpu, bus, instruction, address)

      :data_processing ->
        data_processing(cpu, bus, instruction, address)

      :software_interrupt ->
        CPU.software_interrupt(cpu, bus, instruction &&& 0x00FF_FFFF)

      :undefined ->
        {:error, {:undefined_arm_instruction, instruction, address}, cpu, bus}
    end
  end

  defp branch_exchange(cpu, bus, instruction, address) do
    target = CPU.arm_operand(cpu, instruction &&& 0xF, address)
    {:ok, CPU.exchange(cpu, target), bus, 0}
  end

  defp branch(cpu, bus, instruction, address) do
    offset = instruction |> band(0x00FF_FFFF) |> bsl(2) |> ALU.sign_extend(26)
    cpu = if bit?(instruction, 24), do: CPU.put_register(cpu, 14, address + 4), else: cpu
    target = address + 8 + offset
    cpu = CPU.branch(cpu, target)
    cpu = if target < address, do: CPU.mark_arm_loop(cpu, bus, target, address), else: cpu
    {:ok, cpu, bus, 0}
  end

  defp multiply(cpu, bus, instruction) do
    accumulate? = bit?(instruction, 21)
    set_flags? = bit?(instruction, 20)
    destination = instruction >>> 16 &&& 0xF
    accumulator = instruction >>> 12 &&& 0xF
    multiplier = instruction >>> 8 &&& 0xF
    multiplicand = instruction &&& 0xF

    value = CPU.register(cpu, multiplicand) * CPU.register(cpu, multiplier)
    value = if accumulate?, do: value + CPU.register(cpu, accumulator), else: value
    result = value &&& @mask
    cpu = CPU.put_register(cpu, destination, result)
    cpu = if set_flags?, do: CPU.put_cpsr(cpu, ALU.put_nz(cpu.cpsr, result)), else: cpu
    {:ok, cpu, Bus.idle(bus, 1), 1}
  end

  defp long_multiply(cpu, bus, instruction) do
    signed? = bit?(instruction, 22)
    accumulate? = bit?(instruction, 21)
    set_flags? = bit?(instruction, 20)
    high_register = instruction >>> 16 &&& 0xF
    low_register = instruction >>> 12 &&& 0xF
    multiplier = CPU.register(cpu, instruction >>> 8 &&& 0xF)
    multiplicand = CPU.register(cpu, instruction &&& 0xF)

    {multiplier, multiplicand} =
      if signed? do
        {ALU.sign_extend(multiplier, 32), ALU.sign_extend(multiplicand, 32)}
      else
        {multiplier, multiplicand}
      end

    product = multiplier * multiplicand

    product =
      if accumulate? do
        accumulator =
          CPU.register(cpu, high_register) <<< 32 ||| CPU.register(cpu, low_register)

        product + accumulator
      else
        product
      end

    product = product &&& 0xFFFF_FFFF_FFFF_FFFF

    cpu =
      cpu
      |> CPU.put_register(low_register, product &&& @mask)
      |> CPU.put_register(high_register, product >>> 32)

    cpu = if set_flags?, do: CPU.put_cpsr(cpu, long_flags(cpu.cpsr, product)), else: cpu
    {:ok, cpu, Bus.idle(bus, 2), 2}
  end

  defp data_processing(cpu, bus, instruction, address) do
    opcode = instruction >>> 21 &&& 0xF
    set_flags? = bit?(instruction, 20)
    left = CPU.arm_operand(cpu, instruction >>> 16 &&& 0xF, address)
    destination = instruction >>> 12 &&& 0xF
    {right, shifter_carry} = operand2(cpu, instruction, address)

    {result, flags, write?} = operation(opcode, left, right, shifter_carry, cpu.cpsr)
    restore_status? = set_flags? and write? and destination == 15

    if restore_status? do
      with {:ok, saved_status} <- CPU.fetch_spsr(cpu),
           {:ok, cpu} <- CPU.write_cpsr(cpu, saved_status) do
        {:ok, CPU.branch(cpu, result), bus, 0}
      else
        {:error, reason} -> {:error, reason, cpu, bus}
      end
    else
      update_flags? = set_flags? or opcode in 8..11
      cpu = if update_flags?, do: CPU.put_cpsr(cpu, flags), else: cpu

      cpu =
        cond do
          not write? -> cpu
          destination == 15 -> CPU.branch(cpu, result)
          true -> CPU.put_register(cpu, destination, result)
        end

      {:ok, cpu, bus, 0}
    end
  end

  defp operation(0, left, right, carry, cpsr),
    do: logical(left &&& right, carry, cpsr, true)

  defp operation(1, left, right, carry, cpsr),
    do: logical(bxor(left, right), carry, cpsr, true)

  defp operation(2, left, right, _carry, cpsr), do: subtract(left, right, 0, cpsr, true)
  defp operation(3, left, right, _carry, cpsr), do: subtract(right, left, 0, cpsr, true)
  defp operation(4, left, right, _carry, cpsr), do: add(left, right, 0, cpsr, true)

  defp operation(5, left, right, _carry, cpsr),
    do: add(left, right, if(ALU.carry?(cpsr), do: 1, else: 0), cpsr, true)

  defp operation(6, left, right, _carry, cpsr),
    do: subtract(left, right, if(ALU.carry?(cpsr), do: 0, else: 1), cpsr, true)

  defp operation(7, left, right, _carry, cpsr),
    do: subtract(right, left, if(ALU.carry?(cpsr), do: 0, else: 1), cpsr, true)

  defp operation(8, left, right, carry, cpsr),
    do: logical(left &&& right, carry, cpsr, false)

  defp operation(9, left, right, carry, cpsr),
    do: logical(bxor(left, right), carry, cpsr, false)

  defp operation(10, left, right, _carry, cpsr), do: subtract(left, right, 0, cpsr, false)
  defp operation(11, left, right, _carry, cpsr), do: add(left, right, 0, cpsr, false)

  defp operation(12, left, right, carry, cpsr),
    do: logical(left ||| right, carry, cpsr, true)

  defp operation(13, _left, right, carry, cpsr), do: logical(right, carry, cpsr, true)

  defp operation(14, left, right, carry, cpsr),
    do: logical(left &&& bnot(right), carry, cpsr, true)

  defp operation(15, _left, right, carry, cpsr),
    do: logical(bnot(right) &&& @mask, carry, cpsr, true)

  defp logical(result, carry, cpsr, write?),
    do: {result &&& @mask, ALU.put_nzc(cpsr, result, carry), write?}

  defp add(left, right, carry, cpsr, write?) do
    {result, carry, overflow} = ALU.add(left, right, carry)
    {result, ALU.put_nzcv(cpsr, result, carry, overflow), write?}
  end

  defp subtract(left, right, borrow, cpsr, write?) do
    {result, carry, overflow} = ALU.subtract(left, right, borrow)
    {result, ALU.put_nzcv(cpsr, result, carry, overflow), write?}
  end

  defp operand2(cpu, instruction, address) do
    carry = ALU.carry?(cpu.cpsr)

    if bit?(instruction, 25) do
      ALU.rotate_immediate(instruction &&& 0xFF, instruction >>> 8 &&& 0xF, carry)
    else
      value = CPU.arm_operand(cpu, instruction &&& 0xF, address)
      type = instruction >>> 5 &&& 0x3

      if bit?(instruction, 4) do
        amount = CPU.arm_operand(cpu, instruction >>> 8 &&& 0xF, address) &&& 0xFF
        ALU.shift_register(value, type, amount, carry)
      else
        ALU.shift_immediate(value, type, instruction >>> 7 &&& 0x1F, carry)
      end
    end
  end

  defp single_transfer(cpu, bus, instruction, instruction_address) do
    preindex? = bit?(instruction, 24)
    add? = bit?(instruction, 23)
    byte? = bit?(instruction, 22)
    writeback? = bit?(instruction, 21)
    load? = bit?(instruction, 20)
    base_register = instruction >>> 16 &&& 0xF
    destination = instruction >>> 12 &&& 0xF
    base = CPU.arm_operand(cpu, base_register, instruction_address)
    offset = transfer_offset(cpu, instruction, instruction_address)
    adjusted = if add?, do: base + offset, else: base - offset
    transfer_address = if preindex?, do: adjusted, else: base
    final_base = adjusted &&& @mask

    {cpu, bus, cycles} =
      if load? do
        {value, bus, cycles} =
          if byte?,
            do: Bus.read8(bus, transfer_address),
            else: Bus.read32(bus, transfer_address)

        cpu =
          if destination == 15,
            do: CPU.branch(cpu, value),
            else: CPU.put_register(cpu, destination, value)

        {cpu, bus, cycles}
      else
        value =
          if destination == 15,
            do: instruction_address + 12,
            else: CPU.register(cpu, destination)

        {bus, cycles} =
          if byte?,
            do: Bus.write8(bus, transfer_address, value &&& 0xFF),
            else: Bus.write32(bus, transfer_address, value)

        {cpu, bus, cycles}
      end

    cpu =
      if writeback? or not preindex?,
        do: CPU.put_register(cpu, base_register, final_base),
        else: cpu

    {:ok, cpu, bus, cycles}
  end

  defp transfer_offset(cpu, instruction, address) do
    if bit?(instruction, 25) do
      value = CPU.arm_operand(cpu, instruction &&& 0xF, address)
      type = instruction >>> 5 &&& 0x3
      amount = instruction >>> 7 &&& 0x1F
      {offset, _carry} = ALU.shift_immediate(value, type, amount, ALU.carry?(cpu.cpsr))
      offset
    else
      instruction &&& 0xFFF
    end
  end

  defp halfword_transfer(cpu, bus, instruction, instruction_address) do
    preindex? = bit?(instruction, 24)
    add? = bit?(instruction, 23)
    immediate? = bit?(instruction, 22)
    writeback? = bit?(instruction, 21)
    load? = bit?(instruction, 20)
    base_register = instruction >>> 16 &&& 0xF
    destination = instruction >>> 12 &&& 0xF
    signed? = bit?(instruction, 6)
    halfword? = bit?(instruction, 5)
    base = CPU.arm_operand(cpu, base_register, instruction_address)

    offset =
      if immediate?,
        do: (instruction >>> 4 &&& 0xF0) ||| (instruction &&& 0xF),
        else: CPU.arm_operand(cpu, instruction &&& 0xF, instruction_address)

    adjusted = if add?, do: base + offset, else: base - offset
    transfer_address = if preindex?, do: adjusted, else: base

    with {:ok, cpu, bus, cycles} <-
           halfword_access(
             cpu,
             bus,
             transfer_address,
             destination,
             load?,
             signed?,
             halfword?
           ) do
      cpu =
        if writeback? or not preindex?,
          do: CPU.put_register(cpu, base_register, adjusted),
          else: cpu

      {:ok, cpu, bus, cycles}
    end
  end

  defp halfword_access(cpu, bus, address, destination, false, false, true) do
    {bus, cycles} = Bus.write16(bus, address, CPU.register(cpu, destination) &&& 0xFFFF)
    {:ok, cpu, bus, cycles}
  end

  defp halfword_access(cpu, bus, address, destination, true, false, true) do
    {value, bus, cycles} = Bus.read16(bus, address)
    {:ok, CPU.put_register(cpu, destination, value), bus, cycles}
  end

  defp halfword_access(cpu, bus, address, destination, true, true, false) do
    {value, bus, cycles} = Bus.read8(bus, address)
    {:ok, CPU.put_register(cpu, destination, ALU.sign_extend(value, 8)), bus, cycles}
  end

  defp halfword_access(cpu, bus, address, destination, true, true, true) do
    {value, bus, cycles} = Bus.read16(bus, address)
    {:ok, CPU.put_register(cpu, destination, ALU.sign_extend(value, 16)), bus, cycles}
  end

  defp halfword_access(cpu, bus, _address, _destination, _load, _signed, _halfword),
    do: {:error, :undefined_halfword_transfer, cpu, bus}

  defp block_transfer(cpu, bus, instruction, instruction_address) do
    preindex? = bit?(instruction, 24)
    increment? = bit?(instruction, 23)
    writeback? = bit?(instruction, 21)
    load? = bit?(instruction, 20)
    base_register = instruction >>> 16 &&& 0xF
    registers = for register <- 0..15, bit?(instruction, register), do: register

    if registers == [] do
      {:error, {:empty_register_list, instruction}, cpu, bus}
    else
      count = length(registers)
      base = CPU.arm_operand(cpu, base_register, instruction_address)
      start = block_start(base, count, increment?, preindex?)

      {cpu, bus, cycles} =
        Enum.reduce(Enum.with_index(registers), {cpu, bus, 0}, fn {register, index},
                                                                  {cpu, bus, cycles} ->
          address = start + index * 4

          if load? do
            {value, bus, access_cycles} = Bus.read32(bus, address, access(index))

            cpu =
              if register == 15,
                do: CPU.branch(cpu, value),
                else: CPU.put_register(cpu, register, value)

            {cpu, bus, cycles + access_cycles}
          else
            value =
              if register == 15,
                do: instruction_address + 12,
                else: CPU.register(cpu, register)

            {bus, access_cycles} = Bus.write32(bus, address, value, access(index))
            {cpu, bus, cycles + access_cycles}
          end
        end)

      final_base = if increment?, do: base + count * 4, else: base - count * 4
      cpu = if writeback?, do: CPU.put_register(cpu, base_register, final_base), else: cpu
      {:ok, cpu, bus, cycles}
    end
  end

  defp block_start(base, _count, true, false), do: base
  defp block_start(base, _count, true, true), do: base + 4
  defp block_start(base, count, false, false), do: base - 4 * (count - 1)
  defp block_start(base, count, false, true), do: base - 4 * count

  defp access(0), do: :nonsequential
  defp access(_index), do: :sequential

  defp psr_transfer?(instruction) do
    (instruction &&& 0x0FBF_0FFF) == 0x010F_0000 or
      (instruction &&& 0x0DB0_F000) == 0x0120_F000
  end

  defp psr_transfer(cpu, bus, instruction, address) do
    if (instruction &&& 0x0FBF_0FFF) == 0x010F_0000 do
      move_status_to_register(cpu, bus, instruction, address)
    else
      move_operand_to_status(cpu, bus, instruction, address)
    end
  end

  defp move_status_to_register(cpu, bus, instruction, address) do
    destination = instruction >>> 12 &&& 0xF

    cond do
      destination == 15 ->
        {:error, {:unpredictable_mrs_destination, instruction, address}, cpu, bus}

      bit?(instruction, 22) ->
        case CPU.fetch_spsr(cpu) do
          {:ok, value} -> {:ok, CPU.put_register(cpu, destination, value), bus, 0}
          {:error, reason} -> {:error, reason, cpu, bus}
        end

      true ->
        {:ok, CPU.put_register(cpu, destination, cpu.cpsr), bus, 0}
    end
  end

  defp move_operand_to_status(cpu, bus, instruction, _address) do
    value = status_operand(cpu, instruction)
    mask = status_field_mask(instruction >>> 16 &&& 0xF)

    if bit?(instruction, 22) do
      write_spsr_fields(cpu, bus, value, mask)
    else
      writable_mask = if CPU.privileged?(cpu), do: mask, else: mask &&& 0xFF00_0000
      value = (cpu.cpsr &&& bnot(writable_mask)) ||| (value &&& writable_mask)

      case CPU.write_cpsr(cpu, value) do
        {:ok, cpu} -> {:ok, cpu, bus, 0}
        {:error, reason} -> {:error, reason, cpu, bus}
      end
    end
  end

  defp write_spsr_fields(cpu, bus, value, mask) do
    with {:ok, current} <- CPU.fetch_spsr(cpu),
         {:ok, cpu} <- CPU.put_spsr(cpu, (current &&& bnot(mask)) ||| (value &&& mask)) do
      {:ok, cpu, bus, 0}
    else
      {:error, reason} -> {:error, reason, cpu, bus}
    end
  end

  defp status_operand(cpu, instruction) do
    if bit?(instruction, 25) do
      {value, _carry} =
        ALU.rotate_immediate(
          instruction &&& 0xFF,
          instruction >>> 8 &&& 0xF,
          ALU.carry?(cpu.cpsr)
        )

      value
    else
      CPU.register(cpu, instruction &&& 0xF)
    end
  end

  defp status_field_mask(fields) do
    Enum.reduce(0..3, 0, fn field, mask ->
      if bit?(fields, field), do: mask ||| 0xFF <<< (field * 8), else: mask
    end)
  end

  defp long_flags(cpsr, product) do
    cpsr = cpsr &&& 0x3FFF_FFFF
    cpsr = if product == 0, do: cpsr ||| 0x4000_0000, else: cpsr
    if (product &&& 0x8000_0000_0000_0000) != 0, do: cpsr ||| 0x8000_0000, else: cpsr
  end

  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
