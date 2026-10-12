defmodule Beamicom.GBA.CPU do
  @moduledoc """
  Scalar ARM7TDMI execution state.

  Registers and status are ordinary serializable terms. The interpreter keeps
  the current instruction address in R15; operand helpers expose the ARM or
  Thumb pipeline-visible PC value required by each instruction set.
  """

  import Bitwise

  alias Beamicom.GBA.{
    Bus,
    CPU.ARM,
    CPU.ArmLoop,
    CPU.BlockCache,
    CPU.DecodedBlock,
    CPU.Thumb,
    CPU.ThumbLoop
  }

  @thumb 0x20
  @mask 0xFFFF_FFFF
  @mode_mask 0x1F
  @valid_modes [0x10, 0x11, 0x12, 0x13, 0x17, 0x1B, 0x1F]
  @sine_table (for index <- 0..255 do
                 angle = index * 2 * :math.pi() / 256
                 round(:math.sin(angle) * 16_384)
               end)
              |> List.to_tuple()

  @compile {:inline,
            register: 2, put_register: 3, thumb?: 1, accept_irq?: 2, add_fetch_cycles: 2, step: 2}

  @enforce_keys [:registers, :pc, :cpsr, :banked, :spsr]
  defstruct @enforce_keys ++
              [
                run_state: :running,
                next_fetch: :nonsequential,
                fast_loop: nil,
                fast_loops?: true
              ]

  @doc "Creates reset CPU state or state overridden by keyword options."
  def new(opts \\ []) when is_list(opts) do
    registers = Keyword.get(opts, :registers, List.duplicate(0, 16) |> List.to_tuple())

    if not is_tuple(registers) or tuple_size(registers) != 16 do
      raise ArgumentError, "registers must be a 16-element tuple"
    end

    pc = Keyword.get(opts, :pc, elem(registers, 15))
    registers = put_elem(registers, 13, Keyword.get(opts, :sp, elem(registers, 13)))

    %__MODULE__{
      registers: registers,
      pc: pc,
      cpsr: Keyword.get(opts, :cpsr, 0xD3),
      banked: Keyword.get(opts, :banked, default_banked()),
      spsr: Keyword.get(opts, :spsr, default_spsr()),
      run_state: Keyword.get(opts, :run_state, :running),
      next_fetch: :nonsequential,
      fast_loop: Keyword.get(opts, :fast_loop),
      fast_loops?: Keyword.get(opts, :fast_loops, true)
    }
  end

  @doc "Returns CPU state at the BIOS handoff used by skip-boot diagnostics."
  def post_boot(opts \\ []) when is_list(opts) do
    banked =
      default_banked()
      |> put_in([:irq], {0x0300_7FA0, 0})
      |> put_in([:supervisor], {0x0300_7FE0, 0})

    opts
    |> Keyword.merge(pc: 0x0800_0000, sp: 0x0300_7F00, cpsr: 0x1F, banked: banked)
    |> new()
  end

  @doc "Executes one ARM or Thumb instruction or accepts a pending IRQ."
  def step(%__MODULE__{} = cpu, %Bus{} = bus) do
    cond do
      match?({:interrupt_wait_irq, _, _, _}, cpu.run_state) ->
        service_interrupt_wait_irq(cpu, bus, &execute_running/2)

      match?({:interrupt_wait, _mask}, cpu.run_state) ->
        resume_from_interrupt_wait(cpu, bus)

      accept_irq?(cpu, bus) ->
        {:ok, enter_irq(%{cpu | run_state: :running}), bus, 0}

      cpu.run_state == :halted ->
        resume_from_halt(cpu, bus)

      true ->
        execute_running(cpu, bus)
    end
  end

  @doc false
  def step_scalar(%__MODULE__{} = cpu, %Bus{} = bus) do
    cond do
      match?({:interrupt_wait_irq, _, _, _}, cpu.run_state) ->
        service_interrupt_wait_irq(cpu, bus, &execute_instruction/2)

      match?({:interrupt_wait, _mask}, cpu.run_state) ->
        resume_from_interrupt_wait(cpu, bus)

      accept_irq?(cpu, bus) ->
        {:ok, enter_irq(%{cpu | run_state: :running}), bus, 0}

      cpu.run_state == :halted ->
        resume_from_halt(cpu, bus)

      true ->
        execute_instruction(cpu, bus)
    end
  end

  @doc false
  def run_scalar_until_frame(
        %__MODULE__{} = cpu,
        %Bus{} = bus,
        target_frame,
        instruction_limit
      )
      when is_integer(target_frame) and is_integer(instruction_limit) and instruction_limit >= 0 do
    run_scalar_until_frame(cpu, bus, target_frame, instruction_limit, 0)
  end

  defp run_scalar_until_frame(cpu, bus, _target_frame, 0, executed),
    do: {:error, :frame_timeout, cpu, bus, executed}

  defp run_scalar_until_frame(cpu, bus, target_frame, remaining, executed) do
    case step(cpu, bus) do
      {:ok, cpu, bus, _cycles} ->
        executed = executed + 1

        if bus.ppu.frame_number > target_frame do
          {:ok, cpu, bus, executed}
        else
          run_scalar_until_frame(cpu, bus, target_frame, remaining - 1, executed)
        end

      {:error, reason, cpu, bus} ->
        {:error, reason, cpu, bus, executed + 1}
    end
  end

  @doc false
  def mark_thumb_loop(%__MODULE__{fast_loops?: true} = cpu, %Bus{} = bus, target, branch),
    do: ThumbLoop.mark(cpu, bus, target, branch)

  def mark_thumb_loop(%__MODULE__{} = cpu, %Bus{}, _target, _branch), do: cpu

  @doc false
  def mark_arm_loop(%__MODULE__{fast_loops?: true} = cpu, %Bus{} = bus, target, branch),
    do: ArmLoop.mark(cpu, bus, target, branch)

  def mark_arm_loop(%__MODULE__{} = cpu, %Bus{}, _target, _branch), do: cpu

  @doc false
  def run_cached_block(
        %__MODULE__{fast_loops?: true, fast_loop: fast_loop, cpsr: cpsr} = cpu,
        %Bus{} = bus,
        %DecodedBlock{} = block,
        target_frame,
        instruction_limit
      )
      when not is_nil(fast_loop) and (cpsr &&& @thumb) != 0 and
             is_integer(target_frame) and is_integer(instruction_limit) and instruction_limit > 0 do
    case ThumbLoop.run_block(cpu, bus) do
      :no -> run_decoded_block(cpu, bus, block, target_frame, instruction_limit)
      result -> result
    end
  end

  @doc false
  def run_cached_block(
        %__MODULE__{} = cpu,
        %Bus{} = bus,
        %DecodedBlock{accelerator: nil} = block,
        target_frame,
        instruction_limit
      )
      when is_integer(target_frame) and is_integer(instruction_limit) and instruction_limit > 0,
      do: run_decoded_block(cpu, bus, block, target_frame, instruction_limit)

  def run_cached_block(
        %__MODULE__{} = cpu,
        %Bus{} = bus,
        %DecodedBlock{accelerator: accelerator} = block,
        target_frame,
        instruction_limit
      )
      when not is_nil(accelerator) and is_integer(target_frame) and
             is_integer(instruction_limit) and instruction_limit > 0 do
    case ArmLoop.run(cpu, bus, block, target_frame, instruction_limit) do
      :no -> run_decoded_block(cpu, bus, block, target_frame, instruction_limit)
      result -> result
    end
  end

  defp run_decoded_block(cpu, bus, block, target_frame, instruction_limit) do
    case block.mode do
      :thumb ->
        run_cached_thumb(cpu, bus, block, target_frame, instruction_limit, 0, 0)

      :arm ->
        run_cached_arm(cpu, bus, block, target_frame, instruction_limit, 0, 0)
    end
  end

  @doc "Handles a BIOS software interrupt supported by the HLE boot path."
  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 1) do
    flags = register(cpu, 0) &&& 0xFF
    {:ok, cpu, Bus.register_ram_reset(bus, flags), 0}
  end

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 2),
    do: {:ok, %{cpu | run_state: :halted}, bus, 0}

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 4),
    do: interrupt_wait(cpu, bus, register(cpu, 0) != 0, register(cpu, 1))

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 5),
    do: interrupt_wait(cpu, bus, true, 1)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 6),
    do: divide(cpu, bus, register(cpu, 0), register(cpu, 1))

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 7),
    do: divide(cpu, bus, register(cpu, 1), register(cpu, 0))

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 8) do
    root = cpu |> register(0) |> :math.sqrt() |> trunc()
    {:ok, put_register(cpu, 0, root), bus, 0}
  end

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 9),
    do: arc_tan(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x0A),
    do: arc_tan2(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x0B),
    do: cpu_set(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x0C),
    do: cpu_fast_set(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x0E),
    do: background_affine_set(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x0F),
    do: object_affine_set(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x11),
    do: lz77_uncompress(cpu, bus, :wram)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x12),
    do: lz77_uncompress(cpu, bus, :vram)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x19),
    do: {:ok, cpu, bus, 0}

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, 0x1F),
    do: midi_key_to_frequency(cpu, bus)

  def software_interrupt(%__MODULE__{} = cpu, %Bus{} = bus, number),
    do: {:error, {:software_interrupt, number}, cpu, bus}

  defp execute_instruction(cpu, bus) do
    address = register(cpu, 15)

    if thumb?(cpu) do
      {instruction, bus, fetch_cycles} = Bus.fetch16(bus, address, cpu.next_fetch)

      cpu = %{cpu | pc: address + 2 &&& @mask, next_fetch: :sequential}

      add_fetch_cycles(Thumb.execute(cpu, bus, instruction, address), fetch_cycles)
    else
      {instruction, bus, fetch_cycles} = Bus.fetch32(bus, address, cpu.next_fetch)

      cpu = %{cpu | pc: address + 4 &&& @mask, next_fetch: :sequential}

      add_fetch_cycles(ARM.execute(cpu, bus, instruction, address), fetch_cycles)
    end
  end

  defp execute_running(
         %__MODULE__{fast_loops?: true, fast_loop: fast_loop, cpsr: cpsr} = cpu,
         bus
       )
       when not is_nil(fast_loop) and (cpsr &&& @thumb) != 0 do
    case ThumbLoop.run(cpu, bus) do
      :no -> execute_instruction(cpu, bus)
      result -> result
    end
  end

  defp execute_running(
         %__MODULE__{
           fast_loops?: true,
           fast_loop: {:arm_affine_quad, target, _branch},
           cpsr: cpsr,
           pc: pc
         } = cpu,
         bus
       )
       when (pc == target or pc == target + 4) and (cpsr &&& @thumb) == 0 do
    case ArmLoop.run_scalar(cpu, bus) do
      :no -> execute_instruction(cpu, bus)
      result -> result
    end
  end

  defp execute_running(
         %__MODULE__{
           fast_loops?: true,
           fast_loop: {kind, target, _branch},
           cpsr: cpsr,
           pc: target
         } = cpu,
         bus
       )
       when kind in [:arm_affine_inner, :arm_signed_byte_mix] and (cpsr &&& @thumb) == 0 do
    case ArmLoop.run_scalar(cpu, bus) do
      :no -> execute_instruction(cpu, bus)
      result -> result
    end
  end

  defp execute_running(cpu, bus), do: execute_instruction(cpu, bus)

  defp run_cached_thumb(cpu, bus, _block, target_frame, _remaining, _index, executed)
       when bus.ppu.frame_number > target_frame,
       do: {:ok, cpu, bus, executed}

  defp run_cached_thumb(cpu, bus, _block, _target_frame, 0, _index, executed),
    do: {:ok, cpu, bus, executed}

  defp run_cached_thumb(
         cpu,
         bus,
         %DecodedBlock{instructions: instructions},
         _target_frame,
         _remaining,
         index,
         executed
       )
       when index >= tuple_size(instructions),
       do: {:ok, cpu, bus, executed}

  defp run_cached_thumb(
         %__MODULE__{} = cpu,
         bus,
         %DecodedBlock{} = block,
         target_frame,
         remaining,
         index,
         executed
       ) do
    address = block.start_address + index * 2

    if cpu.run_state == :running and cpu.pc == address and (cpu.cpsr &&& @thumb) != 0 do
      {instruction, kind, sequential?, memory_access?} = elem(block.instructions, index)

      result =
        if accept_irq?(cpu, bus) do
          {:ok, enter_irq(cpu), bus, 0}
        else
          {bus, fetch_cycles} = Bus.charge_rom_fetch16(bus, address, cpu.next_fetch)
          cpu = %{cpu | pc: address + 2 &&& @mask, next_fetch: :sequential}

          add_fetch_cycles(
            Thumb.execute_decoded(cpu, bus, instruction, address, kind),
            fetch_cycles
          )
        end

      case result do
        {:ok, cpu, bus, _cycles} ->
          continue_cached_thumb(
            cpu,
            bus,
            block,
            sequential?,
            memory_access?,
            address,
            index,
            target_frame,
            remaining - 1,
            executed + 1
          )

        {:error, reason, cpu, bus} ->
          {:error, reason, cpu, bus, executed + 1}
      end
    else
      {:ok, cpu, bus, executed}
    end
  end

  defp run_cached_arm(cpu, bus, _block, target_frame, _remaining, _index, executed)
       when bus.ppu.frame_number > target_frame,
       do: {:ok, cpu, bus, executed}

  defp run_cached_arm(cpu, bus, _block, _target_frame, 0, _index, executed),
    do: {:ok, cpu, bus, executed}

  defp run_cached_arm(
         cpu,
         bus,
         %DecodedBlock{instructions: instructions},
         _target_frame,
         _remaining,
         index,
         executed
       )
       when index >= tuple_size(instructions),
       do: {:ok, cpu, bus, executed}

  defp run_cached_arm(
         %__MODULE__{} = cpu,
         bus,
         %DecodedBlock{accelerator: {_kind, index}} = block,
         target_frame,
         remaining,
         index,
         executed
       ) do
    case ArmLoop.run(cpu, bus, block, target_frame, remaining) do
      :no ->
        run_cached_arm_instruction(
          cpu,
          bus,
          block,
          target_frame,
          remaining,
          index,
          executed
        )

      {:ok, cpu, bus, accelerated} ->
        executed = executed + accelerated

        case cached_index(block, cpu.pc, 4) do
          {:ok, next_index} ->
            run_cached_arm(
              cpu,
              bus,
              block,
              target_frame,
              remaining - accelerated,
              next_index,
              executed
            )

          :outside ->
            {:ok, cpu, bus, executed}
        end
    end
  end

  defp run_cached_arm(
         %__MODULE__{} = cpu,
         bus,
         %DecodedBlock{} = block,
         target_frame,
         remaining,
         index,
         executed
       ),
       do:
         run_cached_arm_instruction(
           cpu,
           bus,
           block,
           target_frame,
           remaining,
           index,
           executed
         )

  defp run_cached_arm_instruction(
         %__MODULE__{} = cpu,
         bus,
         %DecodedBlock{} = block,
         target_frame,
         remaining,
         index,
         executed
       ) do
    address = block.start_address + index * 4

    if cpu.run_state == :running and cpu.pc == address and (cpu.cpsr &&& @thumb) == 0 do
      {instruction, kind, sequential?, memory_write?} = elem(block.instructions, index)

      result =
        if accept_irq?(cpu, bus) do
          {:ok, enter_irq(cpu), bus, 0}
        else
          {bus, fetch_cycles} = Bus.charge_rom_fetch32(bus, address, cpu.next_fetch)
          cpu = %{cpu | pc: address + 4 &&& @mask, next_fetch: :sequential}

          add_fetch_cycles(
            ARM.execute_decoded(cpu, bus, instruction, address, kind),
            fetch_cycles
          )
        end

      case result do
        {:ok, cpu, bus, _cycles} ->
          continue_cached_arm(
            cpu,
            bus,
            block,
            sequential?,
            memory_write?,
            address,
            index,
            target_frame,
            remaining - 1,
            executed + 1
          )

        {:error, reason, cpu, bus} ->
          {:error, reason, cpu, bus, executed + 1}
      end
    else
      {:ok, cpu, bus, executed}
    end
  end

  defp continue_cached_thumb(
         cpu,
         bus,
         block,
         sequential?,
         memory_access?,
         address,
         index,
         target_frame,
         remaining,
         executed
       ) do
    if cached_code_current?(block, bus, memory_access?) do
      continue_cached_thumb_flow(
        cpu,
        bus,
        block,
        sequential?,
        address,
        index,
        target_frame,
        remaining,
        executed
      )
    else
      {:ok, cpu, bus, executed}
    end
  end

  defp continue_cached_thumb_flow(
         cpu,
         bus,
         block,
         true,
         _address,
         index,
         target_frame,
         remaining,
         executed
       ),
       do: run_cached_thumb(cpu, bus, block, target_frame, remaining, index + 1, executed)

  defp continue_cached_thumb_flow(
         cpu,
         bus,
         block,
         false,
         address,
         index,
         target_frame,
         remaining,
         executed
       ) do
    case next_cached_index(block, cpu.pc, address, index, 2) do
      {:ok, next_index} ->
        run_cached_thumb(cpu, bus, block, target_frame, remaining, next_index, executed)

      :outside ->
        {:ok, cpu, bus, executed}
    end
  end

  defp continue_cached_arm(
         cpu,
         bus,
         block,
         sequential?,
         memory_write?,
         address,
         index,
         target_frame,
         remaining,
         executed
       ) do
    if cached_code_current?(block, bus, memory_write?) do
      continue_cached_arm_flow(
        cpu,
        bus,
        block,
        sequential?,
        address,
        index,
        target_frame,
        remaining,
        executed
      )
    else
      {:ok, cpu, bus, executed}
    end
  end

  defp continue_cached_arm_flow(
         cpu,
         bus,
         block,
         true,
         _address,
         index,
         target_frame,
         remaining,
         executed
       ),
       do: run_cached_arm(cpu, bus, block, target_frame, remaining, index + 1, executed)

  defp continue_cached_arm_flow(
         cpu,
         bus,
         block,
         false,
         address,
         index,
         target_frame,
         remaining,
         executed
       ) do
    case next_cached_index(block, cpu.pc, address, index, 4) do
      {:ok, next_index} ->
        run_cached_arm(cpu, bus, block, target_frame, remaining, next_index, executed)

      :outside ->
        {:ok, cpu, bus, executed}
    end
  end

  defp cached_code_current?(%DecodedBlock{source: :iwram} = block, bus, true),
    do: BlockCache.block_current?(block, bus)

  defp cached_code_current?(%DecodedBlock{}, _bus, _memory_access?), do: true

  defp next_cached_index(_block, pc, address, index, width) when pc == address + width,
    do: {:ok, index + 1}

  defp next_cached_index(%DecodedBlock{} = block, pc, _address, _index, width),
    do: cached_index(block, pc, width)

  defp cached_index(%DecodedBlock{} = block, pc, width) do
    offset = pc - block.start_address
    index = div(offset, width)

    if offset >= 0 and rem(offset, width) == 0 and index < tuple_size(block.instructions),
      do: {:ok, index},
      else: :outside
  end

  defp resume_from_halt(cpu, bus) do
    {bus, cycles} = Bus.idle_to_next_event(bus)

    cond do
      accept_irq?(cpu, bus) ->
        {:ok, enter_irq(%{cpu | run_state: :running}), bus, cycles}

      Bus.interrupt_requested?(bus) ->
        {:ok, %{cpu | run_state: :running}, bus, cycles}

      true ->
        {:ok, cpu, bus, cycles}
    end
  end

  defp resume_from_interrupt_wait(%__MODULE__{run_state: {:interrupt_wait, mask}} = cpu, bus) do
    flags = Bus.peek16(bus, 0x0300_7FF8)

    cond do
      (flags &&& mask) != 0 ->
        bus = clear_bios_interrupt_flags(bus, mask)
        {:ok, %{cpu | run_state: :running}, bus, 0}

      accept_irq?(cpu, bus) ->
        resume_pc = register(cpu, 15)
        saved_cpsr = cpu.cpsr
        cpu = %{cpu | run_state: {:interrupt_wait_irq, mask, resume_pc, saved_cpsr}}
        {:ok, enter_irq(cpu), bus, 0}

      true ->
        {bus, cycles} = Bus.idle_to_next_event(bus)
        {:ok, cpu, bus, cycles}
    end
  end

  defp service_interrupt_wait_irq(
         %__MODULE__{
           run_state: {:interrupt_wait_irq, mask, resume_pc, saved_cpsr},
           pc: resume_pc,
           cpsr: saved_cpsr
         } = cpu,
         bus,
         _execute
       ) do
    resume_from_interrupt_wait(%{cpu | run_state: {:interrupt_wait, mask}}, bus)
  end

  defp service_interrupt_wait_irq(cpu, bus, execute), do: execute.(cpu, bus)

  defp interrupt_wait(cpu, bus, discard_old?, mask) do
    mask = mask &&& 0x3FFF
    flags = Bus.peek16(bus, 0x0300_7FF8)
    bus = Bus.put8(bus, 0x0400_0208, 1)

    if not discard_old? and (flags &&& mask) != 0 do
      {:ok, cpu, clear_bios_interrupt_flags(bus, mask), 0}
    else
      bus = clear_bios_interrupt_flags(bus, mask)
      {:ok, %{cpu | run_state: {:interrupt_wait, mask}}, bus, 0}
    end
  end

  defp clear_bios_interrupt_flags(bus, mask) do
    flags = Bus.peek16(bus, 0x0300_7FF8) &&& bnot(mask)
    bus |> Bus.put8(0x0300_7FF8, flags &&& 0xFF) |> Bus.put8(0x0300_7FF9, flags >>> 8)
  end

  defp divide(cpu, bus, numerator, denominator) do
    numerator = signed32(numerator)
    denominator = signed32(denominator)

    if denominator == 0 do
      {:error, :division_by_zero, cpu, bus}
    else
      quotient = div(numerator, denominator)
      remainder = rem(numerator, denominator)

      cpu =
        cpu
        |> put_register(0, quotient)
        |> put_register(1, remainder)
        |> put_register(3, abs(quotient))

      {:ok, cpu, bus, 0}
    end
  end

  defp arc_tan(cpu, bus) do
    {angle, a, b} = arc_tan_values(register(cpu, 0) |> signed32())

    cpu =
      cpu
      |> put_register(0, angle)
      |> put_register(1, a)
      |> put_register(3, b)

    {:ok, cpu, bus, 0}
  end

  defp arc_tan2(cpu, bus) do
    x = register(cpu, 0) |> signed32()
    y = register(cpu, 1) |> signed32()

    {angle, a} =
      cond do
        y == 0 ->
          {if(x >= 0, do: 0, else: 0x8000), nil}

        x == 0 ->
          {if(y >= 0, do: 0x4000, else: 0xC000), nil}

        y >= 0 and x >= 0 and x >= y ->
          arc_tan2_angle(div(y <<< 14, x), 0)

        y >= 0 and x < 0 and -x >= y ->
          arc_tan2_angle(div(y <<< 14, x), 0x8000)

        y >= 0 ->
          arc_tan2_reflected(div(x <<< 14, y), 0x4000)

        x <= 0 and -x > -y ->
          arc_tan2_angle(div(y <<< 14, x), 0x8000)

        x > 0 and x >= -y ->
          arc_tan2_angle(div(y <<< 14, x), 0x1_0000)

        true ->
          arc_tan2_reflected(div(x <<< 14, y), 0xC000)
      end

    cpu = cpu |> put_register(0, angle &&& 0xFFFF) |> put_register(3, 0x170)
    cpu = if is_nil(a), do: cpu, else: put_register(cpu, 1, a)
    {:ok, cpu, bus, 0}
  end

  defp arc_tan2_angle(input, offset) do
    {angle, a, _b} = arc_tan_values(input)
    {angle + offset, a}
  end

  defp arc_tan2_reflected(input, offset) do
    {angle, a, _b} = arc_tan_values(input)
    {offset - angle, a}
  end

  defp arc_tan_values(input) do
    a = -((input * input) >>> 14)
    b = ((0xA9 * a) >>> 14) + 0x390
    b = ((b * a) >>> 14) + 0x91C
    b = ((b * a) >>> 14) + 0xFB6
    b = ((b * a) >>> 14) + 0x16AA
    b = ((b * a) >>> 14) + 0x2081
    b = ((b * a) >>> 14) + 0x3651
    b = ((b * a) >>> 14) + 0xA2F9
    angle = ((input * b) >>> 16) |> band(0xFFFF) |> signed16()
    {angle, a, b}
  end

  defp signed32(value) when value >= 0x8000_0000, do: value - 0x1_0000_0000
  defp signed32(value), do: value

  defp signed16(value) when value >= 0x8000, do: value - 0x1_0000
  defp signed16(value), do: value

  defp accept_irq?(cpu, bus),
    do:
      bus.interrupt_master_enable != 0 and
        (bus.interrupt_enable &&& bus.interrupt_flags &&& 0x3FFF) != 0 and
        (cpu.cpsr &&& 0x80) == 0

  defp enter_irq(cpu) do
    saved_cpsr = cpu.cpsr
    return_address = register(cpu, 15) + 4
    irq_cpsr = (saved_cpsr &&& bnot(0xBF)) ||| 0x92

    {:ok, cpu} = write_cpsr(cpu, irq_cpsr)
    {:ok, cpu} = put_spsr(cpu, saved_cpsr)

    cpu
    |> put_register(14, return_address)
    |> branch(0x18)
  end

  defp cpu_set(cpu, bus) do
    control = register(cpu, 2)
    count = control &&& 0x1F_FFFF
    width = if (control &&& 1 <<< 26) != 0, do: 4, else: 2
    fill? = (control &&& 1 <<< 24) != 0

    with {:ok, cpu, bus, cycles} <- copy_memory(cpu, bus, count, width, fill?) do
      cpu = if width == 4, do: advance_copy_registers(cpu, count, width, fill?), else: cpu
      {:ok, cpu, bus, cycles}
    end
  end

  defp cpu_fast_set(cpu, bus) do
    control = register(cpu, 2)
    count = control &&& 0x1F_FFFF
    transfer_count = count |> Kernel.+(7) |> Bitwise.band(bnot(7))
    fill? = (control &&& 1 <<< 24) != 0

    with {:ok, cpu, bus, cycles} <- copy_memory(cpu, bus, transfer_count, 4, fill?) do
      {:ok, advance_copy_registers(cpu, transfer_count, 4, fill?), bus, cycles}
    end
  end

  defp advance_copy_registers(cpu, 0, _width, _fill?), do: cpu

  defp advance_copy_registers(cpu, count, width, fill?) do
    source_advance = if fill?, do: width, else: count * width

    cpu
    |> put_register(0, register(cpu, 0) + source_advance)
    |> put_register(1, register(cpu, 1) + count * width)
  end

  defp background_affine_set(cpu, bus) do
    source = register(cpu, 0)
    destination = register(cpu, 1)
    count = signed32(register(cpu, 2))

    if count <= 0 do
      {:ok, put_register(cpu, 3, 0), bus, 0}
    else
      {bus, cycles} =
        Enum.reduce(0..(count - 1), {bus, 0}, fn index, {bus, cycles} ->
          input = source + index * 20
          output = destination + index * 16
          origin_x = bus |> Bus.peek32(input) |> signed32()
          origin_y = bus |> Bus.peek32(input + 4) |> signed32()
          center_x = bus |> Bus.peek16(input + 8) |> signed16()
          center_y = bus |> Bus.peek16(input + 10) |> signed16()
          scale_x = bus |> Bus.peek16(input + 12) |> signed16()
          scale_y = bus |> Bus.peek16(input + 14) |> signed16()
          angle = Bus.peek16(bus, input + 16)
          {pa, pb, pc, pd} = affine_matrix(scale_x, scale_y, angle)
          reference_x = origin_x - pa * center_x - pb * center_y
          reference_y = origin_y - pc * center_x - pd * center_y

          {bus, write_cycles} =
            bus
            |> write_affine_halfword(output, pa, 0)
            |> write_affine_halfword(output + 2, pb, 0)
            |> write_affine_halfword(output + 4, pc, 0)
            |> write_affine_halfword(output + 6, pd, 0)
            |> write_affine_word(output + 8, reference_x, 0)
            |> write_affine_word(output + 12, reference_y, 0)

          {bus, cycles + write_cycles}
        end)

      cpu =
        cpu
        |> put_register(0, source + count * 20)
        |> put_register(1, destination + count * 16)
        |> put_register(3, 0)

      {:ok, cpu, bus, cycles}
    end
  end

  defp object_affine_set(cpu, bus) do
    source = register(cpu, 0)
    destination = register(cpu, 1)
    count = signed32(register(cpu, 2))
    stride = register(cpu, 3)

    if count <= 0 do
      {:ok, cpu, bus, 0}
    else
      {bus, cycles} =
        Enum.reduce(0..(count - 1), {bus, 0}, fn index, {bus, cycles} ->
          input = source + index * 8
          output = destination + index * 4 * stride
          scale_x = bus |> Bus.peek16(input) |> signed16()
          scale_y = bus |> Bus.peek16(input + 2) |> signed16()
          angle = Bus.peek16(bus, input + 4)

          {bus, write_cycles} =
            affine_matrix(scale_x, scale_y, angle)
            |> Tuple.to_list()
            |> Enum.with_index()
            |> Enum.reduce({bus, 0}, fn {value, coefficient}, {bus, cycles} ->
              write_affine_halfword(bus, output + coefficient * stride, value, cycles)
            end)

          {bus, cycles + write_cycles}
        end)

      cpu =
        cpu
        |> put_register(0, source + count * 8)
        |> put_register(1, destination + count * 4 * stride)

      {:ok, cpu, bus, cycles}
    end
  end

  defp affine_matrix(scale_x, scale_y, angle) do
    index = angle >>> 8 &&& 0xFF
    sine = elem(@sine_table, index)
    cosine = elem(@sine_table, rem(index + 64, 256))

    {
      (cosine * scale_x) >>> 14,
      (-sine * scale_x) >>> 14,
      (sine * scale_y) >>> 14,
      (cosine * scale_y) >>> 14
    }
  end

  defp write_affine_halfword({bus, cycles}, address, value, extra_cycles),
    do: write_affine_halfword(bus, address, value, cycles + extra_cycles)

  defp write_affine_halfword(%Bus{} = bus, address, value, cycles) do
    {bus, write_cycles} = Bus.write16(bus, address, value &&& 0xFFFF)
    {bus, cycles + write_cycles}
  end

  defp write_affine_word({bus, cycles}, address, value, extra_cycles),
    do: write_affine_word(bus, address, value, cycles + extra_cycles)

  defp write_affine_word(bus, address, value, cycles) do
    {bus, write_cycles} = Bus.write32(bus, address, value &&& @mask)
    {bus, cycles + write_cycles}
  end

  defp copy_memory(cpu, bus, 0, _width, _fill?), do: {:ok, cpu, bus, 0}

  defp copy_memory(cpu, bus, count, width, fill?) do
    source = register(cpu, 0)
    destination = register(cpu, 1)

    if fill? do
      {value, bus, read_cycles} = read_width(bus, source, width, :nonsequential)

      {bus, write_cycles} =
        Enum.reduce(0..(count - 1), {bus, 0}, fn index, {bus, cycles} ->
          {bus, access_cycles} =
            write_width(bus, destination + index * width, value, width, access(index))

          {bus, cycles + access_cycles}
        end)

      {:ok, cpu, bus, read_cycles + write_cycles}
    else
      {bus, cycles} =
        Enum.reduce(0..(count - 1), {bus, 0}, fn index, {bus, cycles} ->
          access = access(index)
          {value, bus, read_cycles} = read_width(bus, source + index * width, width, access)

          {bus, write_cycles} =
            write_width(bus, destination + index * width, value, width, access)

          {bus, cycles + read_cycles + write_cycles}
        end)

      {:ok, cpu, bus, cycles}
    end
  end

  defp read_width(bus, address, 2, access), do: Bus.read16(bus, address, access)
  defp read_width(bus, address, 4, access), do: Bus.read32(bus, address, access)

  defp write_width(bus, address, value, 2, access), do: Bus.write16(bus, address, value, access)
  defp write_width(bus, address, value, 4, access), do: Bus.write32(bus, address, value, access)

  defp access(0), do: :nonsequential
  defp access(_index), do: :sequential

  defp lz77_uncompress(cpu, bus, destination_kind) do
    source = register(cpu, 0)
    destination = register(cpu, 1)
    header = Bus.peek32(bus, source)

    if (header &&& 0xFF) == 0x10 do
      size = header >>> 8 &&& 0x00FF_FFFF

      with {:ok, output} <- lz77_decode(bus, source + 4, size) do
        {bus, cycles} = write_lz77(bus, destination, output, destination_kind)
        {:ok, cpu, bus, cycles}
      else
        {:error, reason} -> {:error, reason, cpu, bus}
      end
    else
      {:error, {:invalid_lz77_header, header}, cpu, bus}
    end
  end

  defp lz77_decode(_bus, _source, 0), do: {:ok, <<>>}

  defp lz77_decode(bus, source, size) do
    case lz77_groups(bus, source, size, :array.new(size), 0) do
      {:ok, output, _source} ->
        binary = for index <- 0..(size - 1), into: <<>>, do: <<:array.get(index, output)>>
        {:ok, binary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lz77_groups(_bus, source, size, output, size), do: {:ok, output, source}

  defp lz77_groups(bus, source, size, output, output_position) do
    flags = Bus.peek8(bus, source)

    case lz77_tokens(bus, source + 1, size, output, output_position, flags, 7) do
      {:ok, source, output, output_position} ->
        lz77_groups(bus, source, size, output, output_position)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lz77_tokens(_bus, source, size, output, size, _flags, _bit),
    do: {:ok, source, output, size}

  defp lz77_tokens(_bus, source, _size, output, output_position, _flags, -1),
    do: {:ok, source, output, output_position}

  defp lz77_tokens(bus, source, size, output, output_position, flags, bit) do
    if (flags &&& 1 <<< bit) == 0 do
      byte = Bus.peek8(bus, source)
      output = :array.set(output_position, byte, output)
      lz77_tokens(bus, source + 1, size, output, output_position + 1, flags, bit - 1)
    else
      first = Bus.peek8(bus, source)
      second = Bus.peek8(bus, source + 1)
      length = (first >>> 4) + 3
      displacement = ((first &&& 0xF) <<< 8 ||| second) + 1

      if displacement > output_position do
        {:error, {:invalid_lz77_displacement, displacement, output_position}}
      else
        {output, output_position} =
          lz77_copy(output, output_position, displacement, length, size)

        lz77_tokens(bus, source + 2, size, output, output_position, flags, bit - 1)
      end
    end
  end

  defp lz77_copy(output, output_position, _displacement, _remaining, size)
       when output_position >= size,
       do: {output, output_position}

  defp lz77_copy(output, output_position, _displacement, 0, _size),
    do: {output, output_position}

  defp lz77_copy(output, output_position, displacement, remaining, size) do
    byte = :array.get(output_position - displacement, output)
    output = :array.set(output_position, byte, output)
    lz77_copy(output, output_position + 1, displacement, remaining - 1, size)
  end

  defp write_lz77(bus, destination, output, :wram) do
    output
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce({bus, 0}, fn {byte, index}, {bus, cycles} ->
      {bus, access_cycles} = Bus.write8(bus, destination + index, byte, access(index))
      {bus, cycles + access_cycles}
    end)
  end

  defp write_lz77(bus, destination, output, :vram) do
    output
    |> pad_halfword()
    |> then(fn output -> for <<value::little-16 <- output>>, do: value end)
    |> Enum.with_index()
    |> Enum.reduce({bus, 0}, fn {value, index}, {bus, cycles} ->
      {bus, access_cycles} = Bus.write16(bus, destination + index * 2, value, access(index))
      {bus, cycles + access_cycles}
    end)
  end

  defp pad_halfword(output) when rem(byte_size(output), 2) == 0, do: output
  defp pad_halfword(output), do: output <> <<0>>

  defp midi_key_to_frequency(cpu, bus) do
    wave_frequency = Bus.peek32(bus, register(cpu, 0) + 4)
    midi_key = register(cpu, 1)
    fine_adjustment = register(cpu, 2)
    exponent = (180.0 - midi_key - fine_adjustment / 256.0) / 12.0
    frequency = trunc(wave_frequency / :math.pow(2.0, exponent))
    {:ok, put_register(cpu, 0, frequency), bus, 0}
  end

  @doc "Reads an architectural register."
  def register(%__MODULE__{pc: pc}, 15), do: pc

  def register(%__MODULE__{registers: registers}, index) when index in 0..14,
    do: elem(registers, index)

  @doc "Writes an architectural register with 32-bit wrapping."
  def put_register(%__MODULE__{} = cpu, 15, value), do: %{cpu | pc: value &&& @mask}

  def put_register(%__MODULE__{} = cpu, index, value) when index in 0..14,
    do: %{cpu | registers: put_elem(cpu.registers, index, value &&& @mask)}

  @doc "Returns an ARM operand register, including its pipeline-visible PC."
  def arm_operand(%__MODULE__{}, 15, instruction_address),
    do: instruction_address + 8

  def arm_operand(%__MODULE__{} = cpu, index, _instruction_address),
    do: register(cpu, index)

  @doc "Returns a Thumb operand register, including its pipeline-visible PC."
  def thumb_operand(%__MODULE__{} = _cpu, 15, instruction_address),
    do: instruction_address + 4

  def thumb_operand(%__MODULE__{} = cpu, index, _instruction_address),
    do: register(cpu, index)

  @doc "Branches and selects the execution state from the target bit."
  def exchange(%__MODULE__{} = cpu, target) do
    if (target &&& 1) == 1 do
      cpu |> put_cpsr(cpu.cpsr ||| @thumb) |> branch(target &&& 0xFFFF_FFFE)
    else
      cpu |> put_cpsr(cpu.cpsr &&& bnot(@thumb)) |> branch(target &&& 0xFFFF_FFFC)
    end
  end

  @doc "Branches in the current instruction set."
  def branch(%__MODULE__{} = cpu, target) do
    alignment_mask = if thumb?(cpu), do: 0xFFFF_FFFE, else: 0xFFFF_FFFC

    cpu
    |> put_register(15, target &&& alignment_mask)
    |> Map.put(:next_fetch, :nonsequential)
  end

  @doc "Replaces the current program status register."
  def put_cpsr(%__MODULE__{} = cpu, value) do
    value = value &&& @mask
    old_mode = cpu.cpsr &&& @mode_mask
    new_mode = value &&& @mode_mask

    cpu = if old_mode == new_mode, do: cpu, else: switch_mode(cpu, old_mode, new_mode)
    %{cpu | cpsr: value}
  end

  @doc "Validates and replaces CPSR, including architectural register banking."
  def write_cpsr(%__MODULE__{} = cpu, value) do
    if valid_mode?(value &&& @mode_mask) do
      {:ok, put_cpsr(cpu, value)}
    else
      {:error, {:invalid_processor_mode, value &&& @mode_mask}}
    end
  end

  @doc "Returns the active processor mode."
  def mode(%__MODULE__{cpsr: cpsr}), do: mode_name(cpsr &&& @mode_mask)

  @doc "Returns whether the current mode may update CPSR control fields."
  def privileged?(%__MODULE__{} = cpu), do: mode(cpu) != :user

  @doc "Reads the saved program status register for the active exception mode."
  def fetch_spsr(%__MODULE__{} = cpu) do
    case mode(cpu) do
      mode when mode in [:fiq, :irq, :supervisor, :abort, :undefined] ->
        {:ok, Map.fetch!(cpu.spsr, mode)}

      _mode ->
        {:error, :spsr_unavailable}
    end
  end

  @doc "Writes the saved program status register for the active exception mode."
  def put_spsr(%__MODULE__{} = cpu, value) do
    case mode(cpu) do
      mode when mode in [:fiq, :irq, :supervisor, :abort, :undefined] ->
        {:ok, %{cpu | spsr: Map.put(cpu.spsr, mode, value &&& @mask)}}

      _mode ->
        {:error, :spsr_unavailable}
    end
  end

  @doc "Returns whether the CPU is executing Thumb instructions."
  def thumb?(%__MODULE__{cpsr: cpsr}), do: (cpsr &&& @thumb) != 0

  defp add_fetch_cycles({:ok, cpu, bus, execution_cycles}, fetch_cycles),
    do: {:ok, cpu, bus, fetch_cycles + execution_cycles}

  defp add_fetch_cycles({:error, reason, cpu, bus}, _fetch_cycles),
    do: {:error, reason, cpu, bus}

  defp default_banked do
    %{
      user: {0, 0, 0, 0, 0, 0, 0},
      fiq: {0, 0, 0, 0, 0, 0, 0},
      irq: {0, 0},
      supervisor: {0, 0},
      abort: {0, 0},
      undefined: {0, 0}
    }
  end

  defp default_spsr do
    %{fiq: 0, irq: 0, supervisor: 0, abort: 0, undefined: 0}
  end

  defp switch_mode(cpu, old_mode, new_mode) do
    cpu
    |> save_mode(mode_name(old_mode))
    |> restore_mode(mode_name(new_mode))
  end

  defp save_mode(cpu, :fiq) do
    values = for register <- 8..14, do: register(cpu, register)
    %{cpu | banked: Map.put(cpu.banked, :fiq, List.to_tuple(values))}
  end

  defp save_mode(cpu, mode) do
    common = for register <- 8..12, do: register(cpu, register)
    user_sp = elem(cpu.banked.user, 5)
    user_lr = elem(cpu.banked.user, 6)
    user = List.to_tuple(common ++ [user_sp, user_lr])
    banked = Map.put(cpu.banked, :user, user)

    banked =
      case mode do
        mode when mode in [:user, :system] ->
          Map.put(banked, :user, List.to_tuple(common ++ [register(cpu, 13), register(cpu, 14)]))

        mode when mode in [:irq, :supervisor, :abort, :undefined] ->
          Map.put(banked, mode, {register(cpu, 13), register(cpu, 14)})
      end

    %{cpu | banked: banked}
  end

  defp restore_mode(cpu, :fiq) do
    registers =
      cpu.banked.fiq
      |> Tuple.to_list()
      |> Enum.with_index(8)
      |> Enum.reduce(cpu.registers, fn {value, register}, registers ->
        put_elem(registers, register, value)
      end)

    %{cpu | registers: registers}
  end

  defp restore_mode(cpu, mode) do
    common = cpu.banked.user |> Tuple.to_list() |> Enum.take(5)

    registers =
      common
      |> Enum.with_index(8)
      |> Enum.reduce(cpu.registers, fn {value, register}, registers ->
        put_elem(registers, register, value)
      end)

    {stack_pointer, link_register} =
      case mode do
        mode when mode in [:user, :system] ->
          {elem(cpu.banked.user, 5), elem(cpu.banked.user, 6)}

        mode when mode in [:irq, :supervisor, :abort, :undefined] ->
          Map.fetch!(cpu.banked, mode)
      end

    %{cpu | registers: registers |> put_elem(13, stack_pointer) |> put_elem(14, link_register)}
  end

  defp valid_mode?(mode), do: mode in @valid_modes

  defp mode_name(0x10), do: :user
  defp mode_name(0x11), do: :fiq
  defp mode_name(0x12), do: :irq
  defp mode_name(0x13), do: :supervisor
  defp mode_name(0x17), do: :abort
  defp mode_name(0x1B), do: :undefined
  defp mode_name(0x1F), do: :system
end
