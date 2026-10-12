defmodule Beamicom.GBA.CPU.ArmLoop do
  @moduledoc false

  import Bitwise

  alias Beamicom.GBA.{Bus, CPU}
  alias Beamicom.GBA.CPU.{ALU, DecodedBlock}
  alias Beamicom.GBA.Memory.Region

  @mask 0xFFFF_FFFF
  @instructions_per_outer 76
  @base_cycles_per_outer 86
  @instructions_per_inner_iteration 18
  @cycles_per_inner_iteration 20
  @maximum_cycles_per_inner_iteration 38
  @signed_byte_mix_cycles 14
  @signed_byte_mix_instructions 10
  @code [
    0xE595_6000,
    0xE009_019E,
    0xE080_9BC9,
    0xE00C_099A,
    0xE3CC_C8FF,
    0xE08C_6466,
    0xE08E_E004,
    0xE1B0_9BAE,
    0x0A00_0007,
    0xE3CE_E5FE,
    0xE052_2009,
    0xDAFF_FFD4,
    0xE259_9001,
    0x0080_0001,
    0x11B3_00D9,
    0xE1F3_10D1,
    0xE041_1000,
    0xE295_5101,
    0x3AFF_FFED,
    0xE485_6004,
    0xE258_8004,
    0xCAFF_FFE9
  ]
  @signed_byte_mix_code [
    0xE1D5_00D0,
    0xE0D7_10D1,
    0xE080_0001,
    0xE001_0390,
    0xE1A0_0441,
    0xE310_0080,
    0x1280_0001,
    0xE4C5_0001,
    0xE254_4001,
    0xCAFF_FFF5
  ]
  @inner_code Enum.slice(@code, 1, 18)

  def detect(:arm, instructions) do
    detect_code(instructions, @code, :affine_quad) ||
      detect_code(instructions, @signed_byte_mix_code, :signed_byte_mix)
  end

  def detect(_mode, _instructions), do: nil

  def mark(%CPU{fast_loop: {kind, target, branch}} = cpu, _bus, target, branch)
      when kind in [:arm_affine_quad, :arm_affine_inner, :arm_signed_byte_mix],
      do: cpu

  def mark(
        %CPU{fast_loop: {:arm_affine_quad, outer_target, _outer_branch}} = cpu,
        _bus,
        inner_target,
        inner_branch
      )
      when inner_target == outer_target + 4 and inner_branch == outer_target + 18 * 4,
      do: cpu

  def mark(%CPU{} = cpu, %Bus{} = bus, target, branch) when target < branch do
    descriptor =
      case branch - target do
        68 ->
          if instructions(bus, target, branch) == @inner_code,
            do: {:arm_affine_inner, target, branch}

        84 ->
          if instructions(bus, target, branch) == @code,
            do: {:arm_affine_quad, target, branch}

        36 ->
          if instructions(bus, target, branch) == @signed_byte_mix_code,
            do: {:arm_signed_byte_mix, target, branch}

        _other ->
          nil
      end

    %{cpu | fast_loop: descriptor}
  end

  def mark(%CPU{} = cpu, %Bus{}, _target, _branch), do: %{cpu | fast_loop: nil}

  def run_scalar(
        %CPU{
          fast_loops?: true,
          fast_loop: {:arm_affine_quad, target, _branch},
          pc: target
        } = cpu,
        %Bus{} = bus
      ) do
    scalar_result(run_outer(cpu, bus, target, bus.ppu.frame_number, 2_000_000, 0), bus, target)
  end

  def run_scalar(
        %CPU{
          fast_loops?: true,
          fast_loop: {:arm_affine_inner, target, _branch},
          pc: target
        } = cpu,
        %Bus{} = bus
      ) do
    run_inner(cpu, bus, target)
  end

  def run_scalar(
        %CPU{
          fast_loops?: true,
          fast_loop: {:arm_affine_quad, target, _branch},
          pc: inner_target
        } = cpu,
        %Bus{} = bus
      )
      when inner_target == target + 4 do
    run_inner(cpu, bus, inner_target)
  end

  def run_scalar(
        %CPU{
          fast_loops?: true,
          fast_loop: {:arm_signed_byte_mix, target, _branch},
          pc: target
        } = cpu,
        %Bus{} = bus
      ) do
    scalar_result(run_signed_byte_mix(cpu, bus, target, 2_000_000), bus, target)
  end

  def run_scalar(%CPU{}, %Bus{}), do: :no

  def run(
        %CPU{fast_loops?: true, run_state: :running} = cpu,
        %Bus{} = bus,
        %DecodedBlock{accelerator: {:affine_quad, index}} = block,
        target_frame,
        instruction_limit
      )
      when instruction_limit >= @instructions_per_outer do
    target = block.start_address + index * 4

    if cpu.pc == target and arm?(cpu) and not irq_pending?(cpu, bus) do
      run_outer(cpu, bus, target, target_frame, instruction_limit, 0)
    else
      :no
    end
  end

  def run(
        %CPU{fast_loops?: true, run_state: :running} = cpu,
        %Bus{} = bus,
        %DecodedBlock{accelerator: {:signed_byte_mix, index}} = block,
        _target_frame,
        instruction_limit
      )
      when instruction_limit >= @signed_byte_mix_instructions do
    target = block.start_address + index * 4

    if cpu.pc == target and arm?(cpu) and not irq_pending?(cpu, bus) do
      run_signed_byte_mix(cpu, bus, target, instruction_limit)
    else
      :no
    end
  end

  def run(%CPU{}, %Bus{}, %DecodedBlock{}, _target_frame, _instruction_limit), do: :no

  defp run_outer(cpu, bus, _target, target_frame, remaining, executed)
       when remaining < @instructions_per_outer or bus.ppu.frame_number > target_frame,
       do: accelerated_result(cpu, bus, executed)

  defp run_outer(cpu, bus, target, target_frame, remaining, executed) do
    with true <- cpu.pc == target,
         true <- arm?(cpu),
         false <- irq_pending?(cpu, bus),
         {:ok, next_cpu, next_bus} <- execute_outer(cpu, bus, target),
         true <- event_window?(bus, next_bus.cycle - bus.cycle) do
      executed = executed + @instructions_per_outer

      if next_cpu.pc == target do
        run_outer(
          next_cpu,
          next_bus,
          target,
          target_frame,
          remaining - @instructions_per_outer,
          executed
        )
      else
        {:ok, next_cpu, next_bus, executed}
      end
    else
      _not_safe when executed == 0 -> :no
      _not_safe -> {:ok, cpu, bus, executed}
    end
  end

  defp execute_outer(cpu, bus, target) do
    registers = cpu.registers
    r5 = elem(registers, 5)
    r8 = elem(registers, 8)

    with true <- r5 in 0x0300_0000..0x03FF_FFFF,
         r6 = Bus.peek32(bus, r5),
         registers = put_elem(registers, 6, r6),
         {:ok, registers, cpsr, extra_cycles} <-
           execute_inner(registers, cpu.cpsr, bus, 0, 4, 0),
         r5 = elem(registers, 5),
         r6 = elem(registers, 6),
         {bus, 1} <- Bus.write32(bus, r5, r6),
         {r8, carry, overflow} <- ALU.subtract(r8, 4) do
      registers = registers |> put_elem(5, r5 + 4 &&& @mask) |> put_elem(8, r8)
      cpsr = ALU.put_nzcv(cpsr, r8, carry, overflow)
      repeat? = ALU.condition_passed?(0xC, cpsr)

      cpu = %{
        cpu
        | registers: registers,
          cpsr: cpsr,
          pc: if(repeat?, do: target, else: target + length(@code) * 4),
          next_fetch: if(repeat?, do: :nonsequential, else: :sequential)
      }

      cycles = @base_cycles_per_outer + extra_cycles
      {:ok, cpu, Bus.idle(bus, cycles - 1)}
    else
      _unsafe -> :no
    end
  end

  defp run_inner(cpu, bus, target) do
    iteration = elem(cpu.registers, 5) >>> 30
    batch = inner_batch(bus, 4 - iteration)
    limit = iteration + batch

    with true <- iteration in 0..3,
         true <- batch > 0,
         false <- irq_pending?(cpu, bus),
         {:ok, registers, cpsr, extra_cycles} <-
           execute_inner(cpu.registers, cpu.cpsr, bus, iteration, limit, 0),
         cycles = batch * @cycles_per_inner_iteration + extra_cycles,
         true <- event_window?(bus, cycles),
         {bus, 1} <- Bus.charge_rom_fetch32(bus, target, :nonsequential) do
      repeat? = limit < 4

      cpu = %{
        cpu
        | registers: registers,
          cpsr: cpsr,
          pc: if(repeat?, do: target, else: target + @instructions_per_inner_iteration * 4),
          next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
          fast_loop: completed_inner_fast_loop(cpu.fast_loop, repeat?)
      }

      {:ok, cpu, Bus.idle(bus, cycles - 1), cycles}
    else
      _not_safe -> :no
    end
  end

  defp inner_batch(_bus, remaining) when remaining <= 0, do: 0

  defp inner_batch(bus, remaining) do
    event_batch = event_batch(bus, @maximum_cycles_per_inner_iteration)
    min(remaining, event_batch)
  end

  defp completed_inner_fast_loop(fast_loop, true), do: fast_loop

  defp completed_inner_fast_loop({:arm_affine_quad, _target, _branch} = fast_loop, false),
    do: fast_loop

  defp completed_inner_fast_loop(_fast_loop, false), do: nil

  defp run_signed_byte_mix(cpu, bus, target, instruction_limit) do
    registers = cpu.registers
    destination = elem(registers, 5)
    source = elem(registers, 7)
    remaining = signed32(elem(registers, 4))
    instruction_batch = div(instruction_limit, @signed_byte_mix_instructions)
    event_batch = event_batch(bus, @signed_byte_mix_cycles)
    batch = min(remaining, min(instruction_batch, event_batch))

    with true <- batch > 0,
         true <- destination in 0x0300_0000..0x03FF_FFFF,
         true <- (destination + batch - 1) in 0x0300_0000..0x03FF_FFFF,
         true <- source in 0x0300_0000..0x03FF_FFFF,
         true <- (source + batch - 1) in 0x0300_0000..0x03FF_FFFF do
      destination_offset = destination - 0x0300_0000
      source_offset = source - 0x0300_0000
      multiplier = elem(registers, 3)

      {iwram, r0, r1} =
        mix_signed_bytes(
          bus.iwram,
          destination_offset,
          source_offset,
          multiplier,
          batch,
          0,
          0
        )

      r4 = elem(registers, 4) - batch &&& @mask
      {result, carry, overflow} = ALU.subtract(r4, 0)
      cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
      repeat? = signed32(r4) > 0

      registers =
        registers
        |> put_elem(0, r0)
        |> put_elem(1, r1)
        |> put_elem(4, r4)
        |> put_elem(5, destination + batch &&& @mask)
        |> put_elem(7, source + batch &&& @mask)

      cpu = %{
        cpu
        | registers: registers,
          cpsr: cpsr,
          pc: if(repeat?, do: target, else: target + @signed_byte_mix_instructions * 4),
          next_fetch: if(repeat?, do: :nonsequential, else: :sequential)
      }

      bus = %{bus | iwram: iwram} |> Bus.idle(batch * @signed_byte_mix_cycles)
      {:ok, cpu, bus, batch * @signed_byte_mix_instructions}
    else
      _unsafe -> :no
    end
  end

  defp mix_signed_bytes(iwram, _destination, _source, _multiplier, 0, r0, r1),
    do: {iwram, r0, r1}

  defp mix_signed_bytes(iwram, destination, source, multiplier, remaining, _r0, _r1) do
    destination_value = iwram |> Region.read(destination) |> signed8()
    source_value = iwram |> Region.read(source) |> signed8()
    sum = destination_value + source_value &&& @mask
    product = sum * multiplier &&& @mask
    shifted = product |> signed32() |> bsr(8) |> band(@mask)
    result = if (shifted &&& 0x80) != 0, do: shifted + 1 &&& @mask, else: shifted
    iwram = Region.write(iwram, destination, result &&& 0xFF)

    mix_signed_bytes(
      iwram,
      destination + 1,
      source + 1,
      multiplier,
      remaining - 1,
      result,
      product
    )
  end

  defp execute_inner(registers, cpsr, _bus, limit, limit, extra_cycles),
    do: {:ok, registers, cpsr, extra_cycles}

  defp execute_inner(registers, cpsr, bus, iteration, limit, extra_cycles) do
    r0 = elem(registers, 0)
    r1 = elem(registers, 1)
    r2 = elem(registers, 2)
    r3 = elem(registers, 3)
    r4 = elem(registers, 4)
    r6 = elem(registers, 6)
    r10 = elem(registers, 10)
    r14 = elem(registers, 14)
    r9 = r14 * r1 &&& @mask
    shifted = r9 |> signed32() |> bsr(23) |> band(@mask)
    r9 = r0 + shifted &&& @mask
    r12 = r10 * r9 &&& @mask
    r12 = r12 &&& bnot(0x00FF_0000)
    rotated = (r6 >>> 8 ||| r6 <<< 24) &&& @mask
    r6 = r12 + rotated &&& @mask
    r14 = r14 + r4 &&& @mask
    carry = (r14 &&& 1 <<< 22) != 0
    r9 = r14 >>> 23
    cpsr = ALU.put_nzc(cpsr, r9, carry)

    with false <- ALU.condition_passed?(0x0, cpsr),
         r14 = r14 &&& bnot(0x3F80_0000),
         {r2, carry, overflow} <- ALU.subtract(r2, r9),
         cpsr = ALU.put_nzcv(cpsr, r2, carry, overflow),
         false <- ALU.condition_passed?(0xD, cpsr),
         {r9, carry, overflow} <- ALU.subtract(r9, 1),
         cpsr = ALU.put_nzcv(cpsr, r9, carry, overflow),
         {:ok, r0, r3, conditional_cycles} <- conditional_r0(r0, r1, r9, r3, cpsr, bus),
         r3 = r3 + 1 &&& @mask,
         true <- r3 in 0x0800_0000..0x0DFF_FFFF,
         load_cycles = Bus.rom_fetch_cycles(bus, r3, 1, :nonsequential),
         r1 = Bus.peek8(bus, r3) |> ALU.sign_extend(8) |> band(@mask),
         r1 = r1 - r0 &&& @mask do
      registers =
        registers
        |> put_elem(0, r0)
        |> put_elem(1, r1)
        |> put_elem(2, r2)
        |> put_elem(3, r3)
        |> put_elem(6, r6)
        |> put_elem(9, r9)
        |> put_elem(12, r12)
        |> put_elem(14, r14)

      finish_inner_iteration(
        registers,
        cpsr,
        bus,
        iteration,
        limit,
        extra_cycles + conditional_cycles + load_cycles
      )
    else
      _uncommon -> :no
    end
  end

  defp finish_inner_iteration(registers, cpsr, bus, iteration, limit, extra_cycles) do
    {r5, carry, overflow} = ALU.add(elem(registers, 5), 0x4000_0000)
    cpsr = ALU.put_nzcv(cpsr, r5, carry, overflow)

    if carry == (iteration == 3) do
      execute_inner(
        put_elem(registers, 5, r5),
        cpsr,
        bus,
        iteration + 1,
        limit,
        extra_cycles
      )
    else
      :no
    end
  end

  defp conditional_r0(r0, r1, _r9, r3, cpsr, _bus) when (cpsr &&& 0x4000_0000) != 0,
    do: {:ok, r0 + r1 &&& @mask, r3, 0}

  defp conditional_r0(_r0, _r1, r9, r3, _cpsr, bus) do
    r3 = r3 + r9 &&& @mask

    if r3 in 0x0800_0000..0x0DFF_FFFF do
      r0 = Bus.peek8(bus, r3) |> ALU.sign_extend(8) |> band(@mask)
      {:ok, r0, r3, Bus.rom_fetch_cycles(bus, r3, 1, :nonsequential)}
    else
      :no
    end
  end

  defp event_window?(bus, iteration_cycles) do
    case Bus.cycles_until_next_event(bus) do
      nil ->
        true

      cycles ->
        cycles >= iteration_cycles or Bus.acceleration_safe?(bus, iteration_cycles)
    end
  end

  defp event_batch(bus, cycles_per_iteration) do
    case Bus.cycles_until_next_event(bus) do
      nil ->
        0xFFFF_FFFF

      cycles ->
        batch = div(cycles, cycles_per_iteration)

        if batch == 0 and Bus.acceleration_safe?(bus, cycles_per_iteration),
          do: 1,
          else: batch
    end
  end

  defp detect_code(instructions, code, kind) when tuple_size(instructions) >= length(code) do
    last_start = tuple_size(instructions) - length(code)

    Enum.find_value(0..last_start, fn start ->
      if code
         |> Enum.with_index()
         |> Enum.all?(fn {opcode, index} ->
           elem(elem(instructions, start + index), 0) == opcode
         end),
         do: {kind, start},
         else: false
    end)
  end

  defp detect_code(_instructions, _code, _kind), do: nil

  defp instructions(bus, first, last), do: Enum.map(first..last//4, &Bus.peek32(bus, &1))

  defp scalar_result({:ok, cpu, bus, _executed}, original_bus, target) do
    cpu = if cpu.pc == target, do: cpu, else: %{cpu | fast_loop: nil}
    {:ok, cpu, bus, bus.cycle - original_bus.cycle}
  end

  defp scalar_result(:no, _original_bus, _target), do: :no

  defp accelerated_result(_cpu, _bus, 0), do: :no
  defp accelerated_result(cpu, bus, executed), do: {:ok, cpu, bus, executed}

  defp arm?(cpu), do: (cpu.cpsr &&& 0x20) == 0

  defp irq_pending?(cpu, bus),
    do: Bus.interrupt_pending?(bus) and (cpu.cpsr &&& 0x80) == 0

  defp signed8(value) when value >= 0x80, do: value - 0x100
  defp signed8(value), do: value

  defp signed32(value) when value >= 0x8000_0000, do: value - 0x1_0000_0000
  defp signed32(value), do: value
end
