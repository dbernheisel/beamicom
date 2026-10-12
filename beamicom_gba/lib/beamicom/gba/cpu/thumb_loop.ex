defmodule Beamicom.GBA.CPU.ThumbLoop do
  @moduledoc false

  import Bitwise

  alias Beamicom.GBA.{Bus, CPU}
  alias Beamicom.GBA.CPU.ALU
  alias Beamicom.GBA.Memory.Region

  @mask 0xFFFF_FFFF
  @thumb 0x20
  @halfword_accumulate_cycles 29
  @byte_copy_cycles 15
  @minimum_record_code {
    0x6808,
    0x3036,
    0x7800,
    0x42A8,
    0xDA01,
    0x1C05,
    0x1C1C,
    0x3104,
    0x3301,
    0x42BB,
    0xDBF4
  }
  @byte_fill_code {0x4645, 0x18A8, 0x7004, 0x3201, 0x7808, 0x4282, 0xDDF8}
  @sparse_word_fill_code {0x6002, 0x3008, 0x3102, 0x29FF, 0xD9FA}
  @sparse_halfword_fill_code {0x8008, 0x3108, 0x3A01, 0x2A00, 0xD1FA}
  @stride_halfword_fill_code {0x8020, 0x3408, 0x42AC, 0xD3FB}
  @backward_halfword_copy_code {0x8808, 0x8048, 0x3902, 0x3A01, 0x2A00, 0xD1F9}
  @halfword_scan_code {0x3104, 0x880B, 0x2B00, 0xD003, 0x4298, 0xD1F9}
  @positive_record_scan_code {0x6820, 0x2800, 0xDA02, 0x1C20, 0xF000, 0xF807, 0x3488, 0x42AC,
                              0xD3F6}
  @descending_word_fill_code {0x1419, 0x1C18, 0x4320, 0x6010, 0x3A04, 0x3F01, 0x19C9, 0x2900,
                              0xDB01, 0x2F00, 0xDAF4}
  @empty_bucket_scan_code {0xCE10, 0x1C45, 0x2C00, 0xD007, 0x6862, 0x1C20, 0x4669, 0xF125, 0xFA16,
                           0x6824, 0x2C00, 0xD1F7, 0x1C28, 0x287F, 0xDDF0}
  @byte_poll_zero_code {0x7808, 0x2800, 0xD0FC}
  @byte_compare_poll_code {0x7831, 0x7838, 0x4281, 0xD3FB}
  @halfword_accumulate_timing [
    {0, {:idle, 3}},
    {1, nil},
    {2, nil},
    {3, nil},
    {4, nil},
    {5, nil},
    {6, nil},
    {7, nil}
  ]
  @byte_fill_timing [
    {0, nil},
    {1, nil},
    {2, {:idle, 1}},
    {3, nil},
    {4, {:idle, 1}},
    {5, nil},
    {6, nil}
  ]
  @sparse_fill_timing [{0, {:idle, 1}}, {1, nil}, {2, nil}, {3, nil}, {4, nil}]
  @positive_record_timing [
    {0, {:idle, 1}},
    {1, nil},
    {2, nil},
    {6, nil},
    {7, nil},
    {8, nil}
  ]
  @affine_idle_indices [
    1,
    2,
    3,
    5,
    11,
    12,
    17,
    19,
    24,
    26,
    31,
    33,
    34,
    37,
    39,
    40,
    42,
    43,
    46,
    48,
    49,
    50,
    51,
    52,
    53,
    54,
    55,
    56
  ]
  @affine_transform_code {
    0x4660,
    0x6841,
    0x6802,
    0x9C00,
    0x1C08,
    0x4360,
    0x2800,
    0xDA00,
    0x4448,
    0x13C7,
    0x4250,
    0x9C01,
    0x4360,
    0x2800,
    0xDA00,
    0x4448,
    0x13C6,
    0x9C01,
    0x1C08,
    0x4360,
    0x2800,
    0xDA00,
    0x4448,
    0x13C4,
    0x9900,
    0x1C10,
    0x4348,
    0x2800,
    0xDA00,
    0x4448,
    0x13C2,
    0x9904,
    0x1C08,
    0x4378,
    0x9902,
    0x1808,
    0x1C29,
    0x4371,
    0x1840,
    0x6098,
    0x9904,
    0x1C08,
    0x4360,
    0x9903,
    0x1808,
    0x1C29,
    0x4351,
    0x1840,
    0x60D8,
    0x8818,
    0x801F,
    0x8858,
    0x805E,
    0x8898,
    0x809C,
    0x88D8,
    0x80DA,
    0x3B10,
    0x2208,
    0x4252,
    0x4494,
    0x3D01,
    0x2401,
    0x4264,
    0x44A0,
    0x4640,
    0x283F,
    0xDCBB
  }

  def mark(%CPU{fast_loop: {kind, target, branch}} = cpu, _bus, target, branch)
      when kind in [
             :halfword_accumulate,
             :byte_copy,
             :affine_transform,
             :minimum_record,
             :byte_fill,
             :sparse_word_fill,
             :sparse_halfword_fill,
             :stride_halfword_fill,
             :backward_halfword_copy,
             :halfword_scan,
             :positive_record_scan,
             :descending_word_fill,
             :empty_bucket_scan,
             :byte_poll_zero,
             :byte_compare_poll
           ],
      do: cpu

  def mark(%CPU{} = cpu, %Bus{} = bus, target, branch) when target < branch do
    descriptor =
      case branch - target do
        14 ->
          case instructions(bus, target, branch) do
            {0x8810, 0x1818, 0x0400, 0x0C03, 0x3202, 0x3401, 0x428C, 0xD3F7} ->
              {:halfword_accumulate, target, branch}

            _other ->
              nil
          end

        12 ->
          case instructions(bus, target, branch) do
            {0x7820, 0x7008, 0x3401, 0x3101, 0x3B01, 0x4293, 0xD1F8} ->
              {:byte_copy, target, branch}

            @byte_fill_code ->
              {:byte_fill, target, branch}

            _other ->
              nil
          end

        8 ->
          case instructions(bus, target, branch) do
            @sparse_word_fill_code -> {:sparse_word_fill, target, branch}
            @sparse_halfword_fill_code -> {:sparse_halfword_fill, target, branch}
            _other -> nil
          end

        10 ->
          case instructions(bus, target, branch) do
            @halfword_scan_code -> {:halfword_scan, target, branch}
            @backward_halfword_copy_code -> {:backward_halfword_copy, target, branch}
            _other -> nil
          end

        4 ->
          if instructions(bus, target, branch) == @byte_poll_zero_code,
            do: {:byte_poll_zero, target, branch},
            else: nil

        6 ->
          case instructions(bus, target, branch) do
            @byte_compare_poll_code -> {:byte_compare_poll, target, branch}
            @stride_halfword_fill_code -> {:stride_halfword_fill, target, branch}
            _other -> nil
          end

        20 ->
          case instructions(bus, target, branch) do
            @minimum_record_code -> {:minimum_record, target, branch}
            @descending_word_fill_code -> {:descending_word_fill, target, branch}
            _other -> nil
          end

        28 ->
          if instructions(bus, target, branch) == @empty_bucket_scan_code,
            do: {:empty_bucket_scan, target, branch},
            else: nil

        16 ->
          if instructions(bus, target, branch) == @positive_record_scan_code,
            do: {:positive_record_scan, target, branch},
            else: nil

        134 ->
          if instructions(bus, target, branch) == @affine_transform_code,
            do: {:affine_transform, target, branch},
            else: nil

        _other ->
          nil
      end

    %{cpu | fast_loop: descriptor}
  end

  def mark(%CPU{} = cpu, %Bus{}, _target, _branch), do: %{cpu | fast_loop: nil}

  def run(
        %CPU{
          fast_loop: {:byte_poll_zero, target, _branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    address = elem(cpu.registers, 1)

    with true <- address in 0x0300_0000..0x03FF_FFFF,
         0 <- Region.read(bus.iwram, address - 0x0300_0000),
         cycles_per_iteration = byte_poll_zero_cycles(bus, target),
         batch when batch > 0 <- batch_size(bus, 0xFFFF_FFFF, cycles_per_iteration) do
      run_byte_poll_zero(cpu, bus, target, batch, cycles_per_iteration)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:byte_compare_poll, target, _branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    left_address = elem(cpu.registers, 6)
    right_address = elem(cpu.registers, 7)

    with true <- left_address in 0x0300_0000..0x03FF_FFFF,
         true <- right_address in 0x0300_0000..0x03FF_FFFF,
         left = Region.read(bus.iwram, left_address - 0x0300_0000),
         right = Region.read(bus.iwram, right_address - 0x0300_0000),
         true <- left < right,
         cycles_per_iteration = byte_compare_poll_cycles(bus, target),
         batch when batch > 0 <- batch_size(bus, 0xFFFF_FFFF, cycles_per_iteration) do
      run_byte_compare_poll(
        cpu,
        bus,
        target,
        batch,
        left_address,
        right_address,
        left,
        right,
        cycles_per_iteration
      )
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:halfword_accumulate, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    source = CPU.register(cpu, 2)
    limit = CPU.register(cpu, 1)
    index = CPU.register(cpu, 4)

    if source in 0x0200_0000..0x02FF_FFFF and index < limit do
      remaining = limit - index
      batch = batch_size(bus, remaining, @halfword_accumulate_cycles)
      run_halfword_accumulate(cpu, bus, target, branch, batch)
    else
      :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:byte_copy, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    source = CPU.register(cpu, 4)
    destination = CPU.register(cpu, 1)
    stop = CPU.register(cpu, 2)
    counter = CPU.register(cpu, 3)
    remaining = counter - stop &&& @mask

    with true <- remaining > 0,
         true <- source in 0x0E00_0000..0x0FFF_FFFF,
         true <- destination in 0x0200_0000..0x02FF_FFFF,
         %{type: type, flash_state: :ready, flash_id?: false} when type in [:flash512, :flash1m] <-
           bus.cartridge.backup do
      batch = batch_size(bus, remaining, @byte_copy_cycles)
      run_byte_copy(cpu, bus, target, branch, batch)
    else
      _other -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:affine_transform, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    source = elem(registers, 12)
    output = elem(registers, 3)
    stack = elem(registers, 13)
    counter = elem(registers, 8)
    remaining = counter - 63

    with true <- remaining > 0,
         true <- (source - (remaining - 1) * 8) in 0x0300_0000..0x03FF_FFF8,
         true <- (output - (remaining - 1) * 16) in 0x0300_0000..0x03FF_FFF0,
         true <- stack in 0x0300_0000..0x03FF_FFEC do
      {base_cycles, skip_delta, maximum_cycles} = affine_transform_timing(bus, target)
      batch = batch_size(bus, remaining, maximum_cycles)
      run_affine_transform(cpu, bus, target, branch, batch, base_cycles, skip_delta)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:minimum_record, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    table = elem(registers, 1)
    index = elem(registers, 3)
    limit = elem(registers, 7)
    remaining = signed32(limit) - signed32(index)

    with true <- remaining > 0,
         true <- table in 0x0300_0000..0x03FF_FFFC,
         true <- (table + (remaining - 1) * 4) in 0x0300_0000..0x03FF_FFFC do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      maximum_cycles = nonsequential + 10 * sequential + 4
      batch = batch_size(bus, remaining, maximum_cycles)

      run_minimum_record(cpu, bus, target, branch, batch, nonsequential, sequential)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:byte_fill, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    base = elem(registers, 8)
    counter = elem(registers, 2)
    limit_address = elem(registers, 1)

    with true <- base in 0x0300_0000..0x03FF_FFFF,
         true <- limit_address in 0x0300_0000..0x03FF_FFFF,
         limit = Region.read(bus.iwram, limit_address - 0x0300_0000),
         remaining = signed32(limit) - signed32(counter) + 1,
         true <- remaining > 0,
         true <- (base + counter) in 0x0300_0000..0x03FF_FFFF,
         true <- (base + counter + remaining - 1) in 0x0300_0000..0x03FF_FFFF do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      cycles_per_iteration = nonsequential + 6 * sequential + 2
      batch = batch_size(bus, remaining, cycles_per_iteration)

      run_byte_fill(cpu, bus, target, branch, batch, limit, cycles_per_iteration)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:sparse_word_fill, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    destination = elem(registers, 0)
    counter = elem(registers, 1)
    remaining = if counter <= 0xFF, do: div(0xFF - counter, 2) + 1, else: 0

    with true <- remaining > 0,
         true <- destination in 0x0300_0000..0x03FF_FFFC,
         true <- (destination + (remaining - 1) * 8) in 0x0300_0000..0x03FF_FFFC do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      cycles_per_iteration = nonsequential + 4 * sequential + 1
      batch = batch_size(bus, remaining, cycles_per_iteration)

      run_sparse_word_fill(cpu, bus, target, branch, batch, cycles_per_iteration)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:sparse_halfword_fill, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    destination = elem(registers, 1)
    remaining = elem(registers, 2)

    with true <- remaining > 0,
         true <- destination in 0x0300_0000..0x03FF_FFFE,
         true <- (destination + (remaining - 1) * 8) in 0x0300_0000..0x03FF_FFFE do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      cycles_per_iteration = nonsequential + 4 * sequential + 1
      batch = batch_size(bus, remaining, cycles_per_iteration)

      run_sparse_halfword_fill(cpu, bus, target, branch, batch, cycles_per_iteration)
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:stride_halfword_fill, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    destination = elem(registers, 4)
    limit = elem(registers, 5)
    remaining = if destination < limit, do: div(limit - destination + 7, 8), else: 0

    with true <- remaining > 0,
         true <- destination in 0x0300_0000..0x03FF_FFFE,
         true <- (destination + (remaining - 1) * 8) in 0x0300_0000..0x03FF_FFFE do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      cycles_per_iteration = nonsequential + 3 * sequential + 1
      batch = batch_size(bus, remaining, cycles_per_iteration)

      run_stride_halfword_fill(
        cpu,
        bus,
        target,
        branch,
        batch,
        limit,
        cycles_per_iteration
      )
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:backward_halfword_copy, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    source = elem(registers, 1)
    remaining = elem(registers, 2)

    with true <- remaining > 0,
         {:ok, field, memory, base, access_cycles} <- local_halfword_memory(bus, source),
         true <- rem(source, 2) == 0,
         true <- (source - (remaining - 1) * 2) in base..(base + memory.size - 2),
         true <- (source + 2) in base..(base + memory.size - 2) do
      nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
      sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
      cycles_per_iteration = nonsequential + 5 * sequential + access_cycles * 2
      batch = batch_size(bus, remaining, cycles_per_iteration)

      run_backward_halfword_copy(
        cpu,
        bus,
        target,
        branch,
        batch,
        field,
        memory,
        base,
        access_cycles,
        cycles_per_iteration
      )
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:halfword_scan, target, _branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    address = elem(registers, 1) + 4 &&& @mask
    match = elem(registers, 0) &&& 0xFFFF

    with true <- address in 0x0800_0000..0x0DFF_FFFE,
         nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential),
         sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential),
         event_budget = Bus.cycles_until_next_event(bus),
         {count, cycles, last} when count > 0 <-
           halfword_scan_batch(bus, address, match, nonsequential + 5 * sequential, event_budget) do
      {result, carry, overflow} = ALU.subtract(match, last)

      cpu = %{
        cpu
        | registers:
            registers
            |> put_elem(1, elem(registers, 1) + count * 4 &&& @mask)
            |> put_elem(3, last),
          cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
          pc: target,
          next_fetch: :nonsequential
      }

      timing_traces =
        for index <- 0..(count - 1), do: halfword_scan_timing(address + index * 4)

      {bus, cycles} = advance_loop_timing(bus, target, timing_traces, cycles)
      {:ok, cpu, bus, cycles}
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:positive_record_scan, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    record = elem(registers, 4)
    limit = elem(registers, 5)
    remaining = if record < limit, do: div(limit - record + 0x87, 0x88), else: 0

    with true <- remaining > 0,
         true <- record in 0x0300_0000..0x03FF_FFFC,
         true <- (record + (remaining - 1) * 0x88) in 0x0300_0000..0x03FF_FFFC,
         nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential),
         sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential),
         cycles_per_iteration = 2 * nonsequential + 4 * sequential + 1,
         event_batch = batch_size(bus, remaining, cycles_per_iteration),
         {batch, last} when batch > 0 <-
           positive_record_batch(bus.iwram, record - 0x0300_0000, event_batch) do
      record = record + batch * 0x88 &&& @mask
      {result, carry, overflow} = ALU.subtract(record, limit)
      cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
      repeat? = not carry

      cpu = %{
        cpu
        | registers: registers |> put_elem(0, last) |> put_elem(4, record),
          cpsr: cpsr,
          pc: if(repeat?, do: target, else: branch + 2),
          next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
          fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
      }

      {bus, cycles} =
        advance_loop_timing(
          bus,
          target,
          batch,
          @positive_record_timing,
          batch * cycles_per_iteration
        )

      {:ok, cpu, bus, cycles}
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:descending_word_fill, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    destination = elem(registers, 2)
    source = elem(registers, 3)
    counter = signed32(elem(registers, 7))
    base = signed16(source >>> 16)
    final_counter = max(0, -base)
    remaining = counter - final_counter + 1

    with true <- remaining > 0,
         {:ok, field, memory, memory_base, access_cycles} <- local_word_memory(bus, destination),
         true <- rem(destination, 4) == 0,
         true <-
           (destination - (remaining - 1) * 4) in memory_base..(memory_base + memory.size - 4),
         nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential),
         sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential),
         maximum_cycles = nonsequential + 10 * sequential + access_cycles,
         batch when batch > 0 <- batch_size(bus, remaining, maximum_cycles) do
      run_descending_word_fill(
        cpu,
        bus,
        target,
        branch,
        batch,
        remaining,
        field,
        memory,
        memory_base,
        access_cycles,
        nonsequential,
        sequential
      )
    else
      _unsafe -> :no
    end
  end

  def run(
        %CPU{
          fast_loop: {:empty_bucket_scan, target, branch},
          pc: target,
          next_fetch: :nonsequential,
          run_state: :running
        } = cpu,
        %Bus{} = bus
      )
      when (cpu.cpsr &&& @thumb) != 0 do
    registers = cpu.registers
    index = signed32(elem(registers, 0))
    source = elem(registers, 6)
    remaining = 128 - index

    with true <- index in 0..127,
         {:ok, _field, memory, memory_base, access_cycles} <- local_word_memory(bus, source),
         true <- rem(source, 4) == 0,
         true <- (source + (remaining - 1) * 4) in memory_base..(memory_base + memory.size - 4),
         nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential),
         sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential),
         cycles_per_iteration = 2 * nonsequential + 5 * sequential + access_cycles,
         maximum = batch_size(bus, remaining, cycles_per_iteration),
         batch when batch > 0 <- zero_word_batch(memory, source - memory_base, maximum, 0) do
      run_empty_bucket_scan(
        cpu,
        bus,
        target,
        branch,
        batch,
        access_cycles,
        cycles_per_iteration
      )
    else
      _unsafe -> :no
    end
  end

  def run(%CPU{}, %Bus{}), do: :no

  @doc false
  def run_block(%CPU{} = before, %Bus{} = bus) do
    case run(before, bus) do
      {:ok, accelerated_cpu, accelerated_bus, cycles} ->
        instructions = accelerated_instructions(before, accelerated_cpu, bus, cycles)
        {:ok, accelerated_cpu, accelerated_bus, instructions}

      :no ->
        :no
    end
  end

  defp run_byte_poll_zero(cpu, bus, target, batch, cycles_per_iteration) do
    {result, carry, overflow} = ALU.subtract(0, 0)

    cpu = %{
      cpu
      | registers: put_elem(cpu.registers, 0, 0),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        pc: target,
        next_fetch: :nonsequential
    }

    {bus, cycles} =
      if prefetch_timing?(bus, target) do
        Bus.replay_thumb_byte_poll_zero_timing(bus, target, batch)
      else
        cycles = batch * cycles_per_iteration
        {Bus.idle(bus, cycles), cycles}
      end

    {:ok, cpu, bus, cycles}
  end

  defp run_byte_compare_poll(
         cpu,
         bus,
         target,
         batch,
         left_address,
         right_address,
         left,
         right,
         cycles_per_iteration
       ) do
    {result, carry, overflow} = ALU.subtract(left, right)

    cpu = %{
      cpu
      | registers: cpu.registers |> put_elem(0, right) |> put_elem(1, left),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        pc: target,
        next_fetch: :nonsequential
    }

    {bus, cycles} =
      if prefetch_timing?(bus, target) do
        Bus.replay_thumb_byte_compare_timing(
          bus,
          target,
          batch,
          left_address,
          right_address
        )
      else
        cycles = batch * cycles_per_iteration
        {Bus.idle(bus, cycles), cycles}
      end

    {:ok, cpu, bus, cycles}
  end

  defp run_minimum_record(
         _cpu,
         _bus,
         _target,
         _branch,
         batch,
         _nonsequential,
         _sequential
       )
       when batch < 1,
       do: :no

  defp run_minimum_record(cpu, bus, target, branch, batch, nonsequential, sequential) do
    case minimum_record_batch(
           cpu.registers,
           bus,
           batch,
           nonsequential,
           sequential,
           0,
           []
         ) do
      {:ok, registers, fallback_cycles, timing_traces} ->
        index = elem(registers, 3)
        limit = elem(registers, 7)
        {result, carry, overflow} = ALU.subtract(index, limit)
        cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
        repeat? = ALU.condition_passed?(0xB, cpsr)

        cpu = %{
          cpu
          | registers: registers,
            cpsr: cpsr,
            pc: if(repeat?, do: target, else: branch + 2),
            next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
            fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
        }

        {bus, cycles} = advance_loop_timing(bus, target, timing_traces, fallback_cycles)
        {:ok, cpu, bus, cycles}

      :unsafe ->
        :no
    end
  end

  defp minimum_record_batch(
         registers,
         _bus,
         0,
         _nonsequential,
         _sequential,
         cycles,
         timing_traces
       ),
       do: {:ok, registers, cycles, Enum.reverse(timing_traces)}

  defp minimum_record_batch(
         registers,
         bus,
         remaining,
         nonsequential,
         sequential,
         cycles,
         timing_traces
       ) do
    table = elem(registers, 1)
    index = elem(registers, 3)
    current_minimum = elem(registers, 5)
    pointer = Region.read32(bus.iwram, table - 0x0300_0000)
    value_address = pointer + 54 &&& @mask

    case byte_read_cycles(bus, value_address) do
      {:ok, read_cycles} ->
        value = Bus.peek8(bus, value_address)
        {difference, carry, overflow} = ALU.subtract(value, current_minimum)
        comparison = ALU.put_nzcv(0, difference, carry, overflow)
        keep_minimum? = ALU.condition_passed?(0xA, comparison)

        registers =
          registers
          |> put_elem(0, value)
          |> put_elem(1, table + 4 &&& @mask)
          |> put_elem(3, index + 1 &&& @mask)
          |> maybe_put_minimum(keep_minimum?, index, value)

        instruction_cycles =
          if keep_minimum?,
            do: 2 * nonsequential + 7 * sequential,
            else: nonsequential + 10 * sequential

        minimum_record_batch(
          registers,
          bus,
          remaining - 1,
          nonsequential,
          sequential,
          cycles + instruction_cycles + 1 + read_cycles,
          [minimum_record_timing(keep_minimum?, value_address) | timing_traces]
        )

      :unsafe ->
        :unsafe
    end
  end

  defp maybe_put_minimum(registers, true, _index, _value), do: registers

  defp maybe_put_minimum(registers, false, index, value),
    do: registers |> put_elem(4, index) |> put_elem(5, value)

  defp run_byte_fill(_cpu, _bus, _target, _branch, batch, _limit, _cycles)
       when batch < 1,
       do: :no

  defp run_byte_fill(cpu, bus, target, branch, batch, limit, cycles_per_iteration) do
    registers = cpu.registers
    base = elem(registers, 8)
    counter = elem(registers, 2)
    value = elem(registers, 4) &&& 0xFF
    offset = base + counter - 0x0300_0000
    iwram = Region.write_binary(bus.iwram, offset, :binary.copy(<<value>>, batch))
    counter = counter + batch &&& @mask
    {result, carry, overflow} = ALU.subtract(counter, limit)
    cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
    repeat? = ALU.condition_passed?(0xD, cpsr)

    registers =
      registers
      |> put_elem(0, limit)
      |> put_elem(2, counter)
      |> put_elem(5, base)

    cpu = %{
      cpu
      | registers: registers,
        cpsr: cpsr,
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = %{bus | iwram: iwram}

    {bus, cycles} =
      advance_loop_timing(bus, target, batch, @byte_fill_timing, batch * cycles_per_iteration)

    {:ok, cpu, bus, cycles}
  end

  defp run_sparse_word_fill(_cpu, _bus, _target, _branch, batch, _cycles) when batch < 1,
    do: :no

  defp run_sparse_word_fill(cpu, bus, target, branch, batch, cycles_per_iteration) do
    registers = cpu.registers
    destination = elem(registers, 0)
    counter = elem(registers, 1)
    value = elem(registers, 2)
    iwram = sparse_word_fill(bus.iwram, destination - 0x0300_0000, value, batch)
    destination = destination + batch * 8 &&& @mask
    counter = counter + batch * 2 &&& @mask
    {result, carry, overflow} = ALU.subtract(counter, 0xFF)
    cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
    repeat? = ALU.condition_passed?(0x9, cpsr)

    registers = registers |> put_elem(0, destination) |> put_elem(1, counter)

    cpu = %{
      cpu
      | registers: registers,
        cpsr: cpsr,
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = %{bus | iwram: iwram}

    {bus, cycles} =
      advance_loop_timing(bus, target, batch, @sparse_fill_timing, batch * cycles_per_iteration)

    {:ok, cpu, bus, cycles}
  end

  defp sparse_word_fill(iwram, _destination, _value, 0), do: iwram

  defp sparse_word_fill(iwram, destination, value, remaining) do
    iwram
    |> Region.write32(destination, value)
    |> sparse_word_fill(destination + 8, value, remaining - 1)
  end

  defp run_sparse_halfword_fill(_cpu, _bus, _target, _branch, batch, _cycles)
       when batch < 1,
       do: :no

  defp run_sparse_halfword_fill(cpu, bus, target, branch, batch, cycles_per_iteration) do
    registers = cpu.registers
    destination = elem(registers, 1)
    remaining = elem(registers, 2)
    value = elem(registers, 0) &&& 0xFFFF
    iwram = sparse_halfword_fill(bus.iwram, destination - 0x0300_0000, value, batch)
    destination = destination + batch * 8 &&& @mask
    remaining = remaining - batch &&& @mask
    {result, carry, overflow} = ALU.subtract(remaining, 0)
    cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
    repeat? = remaining != 0

    cpu = %{
      cpu
      | registers: registers |> put_elem(1, destination) |> put_elem(2, remaining),
        cpsr: cpsr,
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = %{bus | iwram: iwram}

    {bus, cycles} =
      advance_loop_timing(bus, target, batch, @sparse_fill_timing, batch * cycles_per_iteration)

    {:ok, cpu, bus, cycles}
  end

  defp sparse_halfword_fill(iwram, _destination, _value, 0), do: iwram

  defp sparse_halfword_fill(iwram, destination, value, remaining) do
    iwram
    |> Region.write16(destination, value)
    |> sparse_halfword_fill(destination + 8, value, remaining - 1)
  end

  defp run_stride_halfword_fill(_cpu, _bus, _target, _branch, batch, _limit, _cycles)
       when batch < 1,
       do: :no

  defp run_stride_halfword_fill(
         cpu,
         bus,
         target,
         branch,
         batch,
         limit,
         cycles_per_iteration
       ) do
    registers = cpu.registers
    destination = elem(registers, 4)
    value = elem(registers, 0) &&& 0xFFFF
    iwram = sparse_halfword_fill(bus.iwram, destination - 0x0300_0000, value, batch)
    destination = destination + batch * 8 &&& @mask
    {result, carry, overflow} = ALU.subtract(destination, limit)
    repeat? = not carry

    cpu = %{
      cpu
      | registers: put_elem(registers, 4, destination),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = %{bus | iwram: iwram}
    timing = [{0, {:idle, 1}}, {1, nil}, {2, nil}, {3, nil}]
    {bus, cycles} = advance_loop_timing(bus, target, batch, timing, batch * cycles_per_iteration)
    {:ok, cpu, bus, cycles}
  end

  defp run_backward_halfword_copy(
         _cpu,
         _bus,
         _target,
         _branch,
         batch,
         _field,
         _memory,
         _base,
         _access_cycles,
         _cycles
       )
       when batch < 1,
       do: :no

  defp run_backward_halfword_copy(
         cpu,
         bus,
         target,
         branch,
         batch,
         field,
         memory,
         base,
         access_cycles,
         cycles_per_iteration
       ) do
    registers = cpu.registers
    source = elem(registers, 1)
    remaining = elem(registers, 2) - batch &&& @mask
    {memory, last} = copy_halfwords_backward(memory, source - base, batch, 0)
    source = source - batch * 2 &&& @mask
    {result, carry, overflow} = ALU.subtract(remaining, 0)
    repeat? = remaining != 0

    cpu = %{
      cpu
      | registers:
          registers
          |> put_elem(0, last)
          |> put_elem(1, source)
          |> put_elem(2, remaining),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = Map.put(bus, field, memory)

    timing = [
      {0, {:idle, access_cycles}},
      {1, {:idle, access_cycles}},
      {2, nil},
      {3, nil},
      {4, nil},
      {5, nil}
    ]

    {bus, cycles} = advance_loop_timing(bus, target, batch, timing, batch * cycles_per_iteration)
    {:ok, cpu, bus, cycles}
  end

  defp run_descending_word_fill(
         cpu,
         bus,
         target,
         branch,
         batch,
         remaining,
         field,
         memory,
         memory_base,
         access_cycles,
         nonsequential,
         sequential
       ) do
    registers = cpu.registers
    destination = elem(registers, 2)
    source = elem(registers, 3)
    value = source ||| elem(registers, 4)
    counter = elem(registers, 7) - batch &&& @mask
    shifted = source |> signed32() |> bsr(16) |> band(@mask)
    accumulator = shifted + counter &&& @mask
    destination_offset = destination - memory_base - (batch - 1) * 4
    words = :binary.copy(<<value::little-32>>, batch)
    memory = Region.write_binary(memory, destination_offset, words)
    destination = destination - batch * 4 &&& @mask
    finished? = batch == remaining
    negative_accumulator? = finished? and signed32(accumulator) < 0

    {cpsr, next_fetch} =
      if negative_accumulator? do
        {result, carry, overflow} = ALU.subtract(accumulator, 0)
        {ALU.put_nzcv(cpu.cpsr, result, carry, overflow), :nonsequential}
      else
        {result, carry, overflow} = ALU.subtract(counter, 0)

        {ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
         if(finished?, do: :sequential, else: :nonsequential)}
      end

    cpu = %{
      cpu
      | registers:
          registers
          |> put_elem(0, value)
          |> put_elem(1, accumulator)
          |> put_elem(2, destination)
          |> put_elem(7, counter),
        cpsr: cpsr,
        pc: if(finished?, do: branch + 2, else: target),
        next_fetch: next_fetch,
        fast_loop: if(finished?, do: nil, else: cpu.fast_loop)
    }

    bus = Map.put(bus, field, memory)
    normal_cycles = nonsequential + 10 * sequential + access_cycles
    exit_cycles = nonsequential + 8 * sequential + access_cycles

    {timing_traces, fallback_cycles} =
      if negative_accumulator? do
        normal = List.duplicate(descending_word_fill_timing(access_cycles, 10), batch - 1)

        {normal ++ [descending_word_fill_timing(access_cycles, 8)],
         (batch - 1) * normal_cycles + exit_cycles}
      else
        {List.duplicate(descending_word_fill_timing(access_cycles, 10), batch),
         batch * normal_cycles}
      end

    {bus, cycles} = advance_loop_timing(bus, target, timing_traces, fallback_cycles)
    {:ok, cpu, bus, cycles}
  end

  defp descending_word_fill_timing(access_cycles, last_index) do
    for index <- 0..last_index do
      {index, if(index == 3, do: {:idle, access_cycles}, else: nil)}
    end
  end

  defp run_empty_bucket_scan(
         cpu,
         bus,
         target,
         branch,
         batch,
         access_cycles,
         cycles_per_iteration
       ) do
    registers = cpu.registers
    index = elem(registers, 0) + batch &&& @mask
    source = elem(registers, 6) + batch * 4 &&& @mask
    {result, carry, overflow} = ALU.subtract(index, 127)
    repeat? = signed32(index) <= 127

    cpu = %{
      cpu
      | registers:
          registers
          |> put_elem(0, index)
          |> put_elem(4, 0)
          |> put_elem(5, index)
          |> put_elem(6, source),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    timing = [
      {0, {:idle, access_cycles}},
      {1, nil},
      {2, nil},
      {3, nil},
      {12, nil},
      {13, nil},
      {14, nil}
    ]

    {bus, cycles} =
      advance_loop_timing(bus, target, batch, timing, batch * cycles_per_iteration)

    {:ok, cpu, bus, cycles}
  end

  defp zero_word_batch(_memory, _offset, maximum, count) when count == maximum, do: count

  defp zero_word_batch(memory, offset, maximum, count) do
    if Region.read32(memory, offset) == 0,
      do: zero_word_batch(memory, offset + 4, maximum, count + 1),
      else: count
  end

  defp copy_halfwords_backward(memory, _source, 0, last), do: {memory, last}

  defp copy_halfwords_backward(memory, source, remaining, _last) do
    value = Region.read16(memory, source)
    memory = Region.write16(memory, source + 2, value)
    copy_halfwords_backward(memory, source - 2, remaining - 1, value)
  end

  defp local_halfword_memory(bus, address) when address in 0x0200_0000..0x02FF_FFFF,
    do: {:ok, :ewram, bus.ewram, 0x0200_0000, 3}

  defp local_halfword_memory(bus, address) when address in 0x0300_0000..0x03FF_FFFF,
    do: {:ok, :iwram, bus.iwram, 0x0300_0000, 1}

  defp local_halfword_memory(_bus, _address), do: :unsafe

  defp local_word_memory(bus, address) when address in 0x0200_0000..0x02FF_FFFF,
    do: {:ok, :ewram, bus.ewram, 0x0200_0000, 6}

  defp local_word_memory(bus, address) when address in 0x0300_0000..0x03FF_FFFF,
    do: {:ok, :iwram, bus.iwram, 0x0300_0000, 1}

  defp local_word_memory(_bus, _address), do: :unsafe

  defp halfword_scan_batch(bus, address, match, instruction_cycles, event_budget),
    do: halfword_scan_batch(bus, address, match, instruction_cycles, event_budget, 0, 0, 0)

  defp halfword_scan_batch(
         bus,
         address,
         match,
         instruction_cycles,
         event_budget,
         count,
         cycles,
         last
       )
       when address in 0x0800_0000..0x0DFF_FFFE do
    value = Bus.peek16(bus, address)

    iteration_cycles =
      instruction_cycles + Bus.rom_fetch_cycles(bus, address, 2, :nonsequential)

    cond do
      value == 0 or value == match ->
        {count, cycles, last}

      not scan_iteration_safe?(bus, event_budget, cycles, iteration_cycles, count) ->
        {count, cycles, last}

      true ->
        halfword_scan_batch(
          bus,
          address + 4,
          match,
          instruction_cycles,
          event_budget,
          count + 1,
          cycles + iteration_cycles,
          value
        )
    end
  end

  defp halfword_scan_batch(
         _bus,
         _address,
         _match,
         _instruction_cycles,
         _event_budget,
         count,
         cycles,
         last
       ),
       do: {count, cycles, last}

  defp scan_iteration_safe?(_bus, nil, _cycles, _iteration_cycles, _count), do: true

  defp scan_iteration_safe?(_bus, budget, cycles, iteration_cycles, _count)
       when cycles + iteration_cycles <= budget,
       do: true

  defp scan_iteration_safe?(bus, _budget, 0, iteration_cycles, 0),
    do: Bus.acceleration_safe?(bus, iteration_cycles)

  defp scan_iteration_safe?(_bus, _budget, _cycles, _iteration_cycles, _count), do: false

  defp positive_record_batch(iwram, offset, maximum),
    do: positive_record_batch(iwram, offset, maximum, 0, 0)

  defp positive_record_batch(_iwram, _offset, maximum, count, last)
       when count == maximum,
       do: {count, last}

  defp positive_record_batch(iwram, offset, maximum, count, last) do
    value = Region.read32(iwram, offset)

    if value < 0x8000_0000 do
      positive_record_batch(iwram, offset + 0x88, maximum, count + 1, value)
    else
      {count, last}
    end
  end

  defp run_halfword_accumulate(_cpu, _bus, _target, _branch, batch) when batch < 2,
    do: :no

  defp run_halfword_accumulate(cpu, bus, target, branch, batch) do
    source = CPU.register(cpu, 2)
    index = CPU.register(cpu, 4)
    limit = CPU.register(cpu, 1)

    values = Region.read_binary(bus.ewram, source - 0x0200_0000, batch * 2)

    sum =
      for <<value::little-16 <- values>>, reduce: CPU.register(cpu, 3) do
        accumulator -> accumulator + value &&& 0xFFFF
      end

    source = source + batch * 2 &&& @mask
    index = index + batch &&& @mask
    {result, carry, overflow} = ALU.subtract(index, limit)
    registers = cpu.registers
    registers = put_elem(registers, 0, sum <<< 16 &&& @mask)
    registers = put_elem(registers, 2, source)
    registers = put_elem(registers, 3, sum)
    registers = put_elem(registers, 4, index)
    finished? = index == limit

    cpu = %{
      cpu
      | registers: registers,
        pc: if(finished?, do: branch + 2, else: target),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        next_fetch: if(finished?, do: :sequential, else: :nonsequential)
    }

    {bus, cycles} =
      advance_loop_timing(
        bus,
        target,
        batch,
        @halfword_accumulate_timing,
        batch * @halfword_accumulate_cycles
      )

    {:ok, cpu, bus, cycles}
  end

  defp run_byte_copy(_cpu, _bus, _target, _branch, batch) when batch < 2, do: :no

  defp run_byte_copy(cpu, bus, target, branch, batch) do
    source = CPU.register(cpu, 4)
    destination = CPU.register(cpu, 1)
    stop = CPU.register(cpu, 2)
    counter = CPU.register(cpu, 3)
    backup = bus.cartridge.backup
    backup_offset = backup.flash_bank * 0x1_0000 + (source &&& 0xFFFF)
    bytes = Region.read_binary(backup.data, backup_offset, batch)
    ewram = Region.write_binary(bus.ewram, destination - 0x0200_0000, bytes)
    source = source + batch &&& @mask
    destination = destination + batch &&& @mask
    counter = counter - batch &&& @mask
    {result, carry, overflow} = ALU.subtract(counter, stop)
    registers = cpu.registers
    registers = put_elem(registers, 0, :binary.at(bytes, batch - 1))
    registers = put_elem(registers, 1, destination)
    registers = put_elem(registers, 3, counter)
    registers = put_elem(registers, 4, source)
    finished? = counter == stop

    cpu = %{
      cpu
      | registers: registers,
        pc: if(finished?, do: branch + 2, else: target),
        cpsr: ALU.put_nzcv(cpu.cpsr, result, carry, overflow),
        next_fetch: if(finished?, do: :sequential, else: :nonsequential)
    }

    cycles = batch * @byte_copy_cycles
    bus = %{bus | ewram: ewram}
    {:ok, cpu, Bus.idle(bus, cycles), cycles}
  end

  defp run_affine_transform(
         _cpu,
         _bus,
         _target,
         _branch,
         batch,
         _base_cycles,
         _skip_delta
       )
       when batch < 1,
       do: :no

  defp run_affine_transform(cpu, bus, target, branch, batch, base_cycles, skip_delta) do
    registers = cpu.registers
    stack = elem(registers, 13) - 0x0300_0000
    stack0 = Region.read32(bus.iwram, stack)
    stack4 = Region.read32(bus.iwram, stack + 4)
    stack8 = Region.read32(bus.iwram, stack + 8)
    stack12 = Region.read32(bus.iwram, stack + 12)
    stack16 = Region.read32(bus.iwram, stack + 16)

    {registers, iwram, skip_patterns} =
      affine_transform_batch(
        registers,
        bus.iwram,
        {stack0, stack4, stack8, stack12, stack16},
        batch
      )

    skipped_adds =
      Enum.reduce(skip_patterns, 0, fn pattern, total ->
        total + Enum.sum(Tuple.to_list(pattern))
      end)

    counter = elem(registers, 8)
    {result, carry, overflow} = ALU.subtract(counter, 63)
    cpsr = ALU.put_nzcv(cpu.cpsr, result, carry, overflow)
    repeat? = counter > 63

    cpu = %{
      cpu
      | registers: registers,
        cpsr: cpsr,
        pc: if(repeat?, do: target, else: branch + 2),
        next_fetch: if(repeat?, do: :nonsequential, else: :sequential),
        fast_loop: if(repeat?, do: cpu.fast_loop, else: nil)
    }

    bus = %{bus | iwram: iwram}
    timing_traces = Enum.map(skip_patterns, &affine_transform_timing/1)
    fallback_cycles = batch * base_cycles + skipped_adds * skip_delta
    {bus, cycles} = advance_loop_timing(bus, target, timing_traces, fallback_cycles)
    {:ok, cpu, bus, cycles}
  end

  defp affine_transform_batch(registers, iwram, _stack, 0), do: {registers, iwram, []}

  defp affine_transform_batch(registers, iwram, stack, remaining) do
    {stack0, stack4, stack8, stack12, stack16} = stack
    source = elem(registers, 12) - 0x0300_0000
    output = elem(registers, 3) - 0x0300_0000
    r1_source = Region.read32(iwram, source + 4)
    r2_source = Region.read32(iwram, source)
    rounding = elem(registers, 9)
    {r7, skip7} = affine_component(r1_source, stack0, rounding)
    {r6, skip6} = affine_component(-r2_source &&& @mask, stack4, rounding)
    {r4, skip4} = affine_component(r1_source, stack4, rounding)
    {r2, skip2} = affine_component(r2_source, stack0, rounding)
    r5 = elem(registers, 5)
    first_word = stack16 * r7 + stack8 + r5 * r6 &&& @mask
    second_word = stack16 * r4 + stack12 + r5 * r2 &&& @mask

    iwram =
      iwram
      |> Region.write16(output, r7 &&& 0xFFFF)
      |> Region.write16(output + 2, r6 &&& 0xFFFF)
      |> Region.write16(output + 4, r4 &&& 0xFFFF)
      |> Region.write16(output + 6, r2 &&& 0xFFFF)
      |> Region.write32(output + 8, first_word)
      |> Region.write32(output + 12, second_word)

    r1 = r5 * r2 &&& @mask
    r8 = elem(registers, 8) - 1 &&& @mask

    registers =
      registers
      |> put_elem(0, r8)
      |> put_elem(1, r1)
      |> put_elem(2, @mask - 7)
      |> put_elem(3, elem(registers, 3) - 16 &&& @mask)
      |> put_elem(4, @mask)
      |> put_elem(5, r5 - 1 &&& @mask)
      |> put_elem(6, r6)
      |> put_elem(7, r7)
      |> put_elem(8, r8)
      |> put_elem(12, elem(registers, 12) - 8 &&& @mask)

    {registers, iwram, skip_patterns} =
      affine_transform_batch(registers, iwram, stack, remaining - 1)

    {registers, iwram, [{skip7, skip6, skip4, skip2} | skip_patterns]}
  end

  defp affine_component(left, right, rounding) do
    product = left * right &&& @mask
    negative? = product >= 0x8000_0000
    adjusted = if negative?, do: product + rounding &&& @mask, else: product
    component = adjusted |> signed32() |> bsr(15) |> band(@mask)
    {component, if(negative?, do: 0, else: 1)}
  end

  defp affine_transform_timing(bus, target) do
    nonsequential = Bus.rom_fetch_cycles(bus, target, 2, :nonsequential)
    sequential = Bus.rom_fetch_cycles(bus, target, 2, :sequential)
    base = nonsequential + 67 * sequential + 28
    skip_delta = nonsequential - 2 * sequential
    {base, skip_delta, base + max(skip_delta, 0) * 4}
  end

  defp batch_size(bus, remaining, cycles_per_iteration) do
    event_limit =
      case Bus.cycles_until_next_event(bus) do
        nil ->
          remaining

        cycles ->
          batch = div(cycles, cycles_per_iteration)

          if batch == 0 and Bus.acceleration_safe?(bus, cycles_per_iteration),
            do: 1,
            else: batch
      end

    min(remaining, event_limit)
  end

  defp byte_read_cycles(_bus, address) when address in 0x0200_0000..0x02FF_FFFF,
    do: {:ok, 3}

  defp byte_read_cycles(_bus, address) when address in 0x0300_0000..0x03FF_FFFF,
    do: {:ok, 1}

  defp byte_read_cycles(bus, address) when address in 0x0800_0000..0x0DFF_FFFF,
    do: {:ok, Bus.rom_fetch_cycles(bus, address, 1, :nonsequential)}

  defp byte_read_cycles(_bus, _address), do: :unsafe

  defp accelerated_instructions(before, accelerated_cpu, bus, cycles) do
    case before.fast_loop do
      {:byte_poll_zero, target, _branch} ->
        div(cycles, byte_poll_zero_cycles(bus, target)) * 3

      {:byte_compare_poll, target, _branch} ->
        div(cycles, byte_compare_poll_cycles(bus, target)) * 4

      {:halfword_accumulate, _target, _branch} ->
        (CPU.register(accelerated_cpu, 4) - CPU.register(before, 4)) * 8

      {:byte_copy, _target, _branch} ->
        (CPU.register(before, 3) - CPU.register(accelerated_cpu, 3)) * 7

      {:affine_transform, _target, _branch} ->
        (CPU.register(before, 8) - CPU.register(accelerated_cpu, 8)) * 68

      {:minimum_record, _target, _branch} ->
        (CPU.register(accelerated_cpu, 3) - CPU.register(before, 3)) * 11

      {:byte_fill, _target, _branch} ->
        (CPU.register(accelerated_cpu, 2) - CPU.register(before, 2)) * 7

      {:sparse_word_fill, _target, _branch} ->
        div(CPU.register(accelerated_cpu, 1) - CPU.register(before, 1), 2) * 5

      {:sparse_halfword_fill, _target, _branch} ->
        (CPU.register(before, 2) - CPU.register(accelerated_cpu, 2)) * 5

      {:stride_halfword_fill, _target, _branch} ->
        div(CPU.register(accelerated_cpu, 4) - CPU.register(before, 4), 8) * 4

      {:backward_halfword_copy, _target, _branch} ->
        (CPU.register(before, 2) - CPU.register(accelerated_cpu, 2)) * 6

      {:halfword_scan, _target, _branch} ->
        div(CPU.register(accelerated_cpu, 1) - CPU.register(before, 1), 4) * 6

      {:positive_record_scan, _target, _branch} ->
        div(CPU.register(accelerated_cpu, 4) - CPU.register(before, 4), 0x88) * 6

      {:descending_word_fill, _target, branch} ->
        count = (CPU.register(before, 7) - CPU.register(accelerated_cpu, 7)) * 11

        if accelerated_cpu.pc == branch + 2 and signed32(CPU.register(accelerated_cpu, 1)) < 0,
          do: count - 2,
          else: count

      {:empty_bucket_scan, _target, _branch} ->
        (CPU.register(accelerated_cpu, 0) - CPU.register(before, 0)) * 7
    end
  end

  defp byte_poll_zero_cycles(bus, target) do
    Bus.rom_fetch_cycles(bus, target, 2, :nonsequential) +
      2 * Bus.rom_fetch_cycles(bus, target, 2, :sequential) + 1
  end

  defp byte_compare_poll_cycles(bus, target) do
    Bus.rom_fetch_cycles(bus, target, 2, :nonsequential) +
      3 * Bus.rom_fetch_cycles(bus, target, 2, :sequential) + 2
  end

  defp advance_loop_timing(bus, target, batch, timing_trace, fallback_cycles) do
    if prefetch_timing?(bus, target) do
      Bus.replay_thumb_timing(bus, target, batch, timing_trace)
    else
      {Bus.idle(bus, fallback_cycles), fallback_cycles}
    end
  end

  defp advance_loop_timing(bus, target, timing_traces, fallback_cycles) do
    if prefetch_timing?(bus, target) do
      Bus.replay_thumb_timing(bus, target, timing_traces)
    else
      {Bus.idle(bus, fallback_cycles), fallback_cycles}
    end
  end

  defp minimum_record_timing(true, value_address) do
    [
      {0, {:idle, 1}},
      {1, nil},
      {2, {:read8, value_address}},
      {3, nil},
      {4, nil},
      {7, nil},
      {8, nil},
      {9, nil},
      {10, nil}
    ]
  end

  defp minimum_record_timing(false, value_address) do
    for index <- 0..10 do
      action =
        case index do
          0 -> {:idle, 1}
          2 -> {:read8, value_address}
          _other -> nil
        end

      {index, action}
    end
  end

  defp halfword_scan_timing(value_address) do
    for index <- 0..5 do
      {index, if(index == 1, do: {:read16, value_address}, else: nil)}
    end
  end

  defp affine_transform_timing({skip7, skip6, skip4, skip2}) do
    skipped =
      [{skip7, 8}, {skip6, 15}, {skip4, 22}, {skip2, 29}]
      |> Enum.filter(fn {skip?, _index} -> skip? == 1 end)
      |> Enum.map(fn {_skip?, index} -> index end)

    for index <- 0..67, index not in skipped do
      {index, if(index in @affine_idle_indices, do: {:idle, 1}, else: nil)}
    end
  end

  defp prefetch_timing?(bus, target),
    do: target in 0x0800_0000..0x0DFF_FFFF and (bus.waitcnt &&& 0x4000) != 0

  defp instructions(bus, first, last) do
    first..last//2
    |> Enum.map(&Bus.peek16(bus, &1))
    |> List.to_tuple()
  end

  defp signed32(value) when value >= 0x8000_0000, do: value - 0x1_0000_0000
  defp signed32(value), do: value

  defp signed16(value) when value >= 0x8000, do: value - 0x1_0000
  defp signed16(value), do: value
end
