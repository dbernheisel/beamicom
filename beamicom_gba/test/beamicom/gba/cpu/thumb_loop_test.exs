defmodule Beamicom.GBA.CPU.ThumbLoopTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Bus, CPU, Machine, TestROM}
  alias Beamicom.GBA.CPU.ThumbLoop
  alias Beamicom.GBA.Memory.Region

  @target 0x0800_0000
  @program <<
    0x8810::little-16,
    0x1818::little-16,
    0x0400::little-16,
    0x0C03::little-16,
    0x3202::little-16,
    0x3401::little-16,
    0x428C::little-16,
    0xD3F7::little-16
  >>
  @affine_program for(
                    instruction <- [
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
                    ],
                    into: <<>>,
                    do: <<instruction::little-16>>
                  )
  @minimum_record_program for(
                            instruction <- [
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
                            ],
                            into: <<>>,
                            do: <<instruction::little-16>>
                          )
  @byte_fill_program for(
                       instruction <- [0x4645, 0x18A8, 0x7004, 0x3201, 0x7808, 0x4282, 0xDDF8],
                       into: <<>>,
                       do: <<instruction::little-16>>
                     )
  @sparse_word_fill_program for(
                              instruction <- [0x6002, 0x3008, 0x3102, 0x29FF, 0xD9FA],
                              into: <<>>,
                              do: <<instruction::little-16>>
                            )
  @sparse_halfword_fill_program for(
                                  instruction <- [0x8008, 0x3108, 0x3A01, 0x2A00, 0xD1FA],
                                  into: <<>>,
                                  do: <<instruction::little-16>>
                                )
  @stride_halfword_fill_program for(
                                  instruction <- [0x8020, 0x3408, 0x42AC, 0xD3FB],
                                  into: <<>>,
                                  do: <<instruction::little-16>>
                                )
  @backward_halfword_copy_program for(
                                    instruction <- [
                                      0x8808,
                                      0x8048,
                                      0x3902,
                                      0x3A01,
                                      0x2A00,
                                      0xD1F9
                                    ],
                                    into: <<>>,
                                    do: <<instruction::little-16>>
                                  )
  @halfword_scan_program for(
                           instruction <- [0x3104, 0x880B, 0x2B00, 0xD003, 0x4298, 0xD1F9],
                           into: <<>>,
                           do: <<instruction::little-16>>
                         )
  @positive_record_scan_program for(
                                  instruction <- [
                                    0x6820,
                                    0x2800,
                                    0xDA02,
                                    0x1C20,
                                    0xF000,
                                    0xF807,
                                    0x3488,
                                    0x42AC,
                                    0xD3F6
                                  ],
                                  into: <<>>,
                                  do: <<instruction::little-16>>
                                )
  @descending_word_fill_program for(
                                  instruction <- [
                                    0x1419,
                                    0x1C18,
                                    0x4320,
                                    0x6010,
                                    0x3A04,
                                    0x3F01,
                                    0x19C9,
                                    0x2900,
                                    0xDB01,
                                    0x2F00,
                                    0xDAF4
                                  ],
                                  into: <<>>,
                                  do: <<instruction::little-16>>
                                )
  @empty_bucket_scan_program for(
                               instruction <- [
                                 0xCE10,
                                 0x1C45,
                                 0x2C00,
                                 0xD007,
                                 0x6862,
                                 0x1C20,
                                 0x4669,
                                 0xF125,
                                 0xFA16,
                                 0x6824,
                                 0x2C00,
                                 0xD1F7,
                                 0x1C28,
                                 0x287F,
                                 0xDDF0
                               ],
                               into: <<>>,
                               do: <<instruction::little-16>>
                             )
  @byte_poll_zero_program for(
                            instruction <- [0x7808, 0x2800, 0xD0FC],
                            into: <<>>,
                            do: <<instruction::little-16>>
                          )
  @byte_compare_poll_program for(
                               instruction <- [0x7831, 0x7838, 0x4281, 0xD3FB],
                               into: <<>>,
                               do: <<instruction::little-16>>
                             )

  test "zero-byte polling advances to the next hardware event with scalar timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@byte_poll_zero_program), cpu_executor: :scalar)

    address = 0x0300_1000
    registers = machine.cpu.registers |> put_elem(0, 0xFF) |> put_elem(1, address)
    cpu = %{machine.cpu | registers: registers, cpsr: 0x3F}
    cpu = ThumbLoop.mark(cpu, machine.bus, @target, @target + 4)

    assert {:ok, accelerated_cpu, accelerated_bus, 960} = CPU.step(cpu, machine.bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, machine.bus, 80 * 3)

    assert accelerated_cpu == scalar_cpu
    assert accelerated_bus == scalar_bus
    assert accelerated_bus.ppu.phase == :hblank
  end

  test "byte-comparison polling advances to the next hardware event with scalar timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@byte_compare_poll_program), cpu_executor: :scalar)

    left_address = 0x0300_1000
    right_address = left_address + 1

    iwram =
      machine.bus.iwram
      |> Region.write(left_address - 0x0300_0000, 0)
      |> Region.write(right_address - 0x0300_0000, 1)

    bus = %{machine.bus | iwram: iwram}

    registers =
      machine.cpu.registers
      |> put_elem(0, 0xFF)
      |> put_elem(1, 0xFF)
      |> put_elem(6, left_address)
      |> put_elem(7, right_address)

    cpu = %{machine.cpu | registers: registers, cpsr: 0x3F}
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 6)

    assert {:ok, accelerated_cpu, accelerated_bus, 960} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 60 * 4)

    assert accelerated_cpu == scalar_cpu
    assert accelerated_bus == scalar_bus
    assert accelerated_bus.ppu.phase == :hblank
  end

  test "byte-comparison polling preserves enabled Game Pak prefetch timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@byte_compare_poll_program), cpu_executor: :scalar)

    left_address = 0x0300_1000
    right_address = left_address + 1

    iwram =
      machine.bus.iwram
      |> Region.write(left_address - 0x0300_0000, 0)
      |> Region.write(right_address - 0x0300_0000, 1)

    bus = %{machine.bus | iwram: iwram} |> Bus.put8(0x0400_0205, 0x40)

    registers =
      machine.cpu.registers
      |> put_elem(6, left_address)
      |> put_elem(7, right_address)

    cpu = %{machine.cpu | registers: registers, cpsr: 0x3F}
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 6)

    assert {:ok, accelerated_cpu, accelerated_bus, 840} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 60 * 4)

    assert accelerated_cpu == scalar_cpu
    assert accelerated_bus == scalar_bus
  end

  test "halfword accumulator batching matches every scalar instruction" do
    assert {:ok, machine} = Machine.load(TestROM.build(@program), cpu_executor: :scalar)

    values = for value <- 1..100, into: <<>>, do: <<value::little-16>>
    bus = %{machine.bus | ewram: Region.write_binary(machine.bus.ewram, 0, values)}

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(1, 100)
      |> put_elem(2, 0x0200_0000)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 14)

    assert {:ok, accelerated_cpu, accelerated_bus, 957} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 33 * 8)

    assert accelerated_cpu == scalar_cpu
    assert accelerated_bus == scalar_bus
  end

  test "affine transform batching matches every scalar instruction" do
    assert {:ok, machine} = Machine.load(TestROM.build(@affine_program), cpu_executor: :scalar)
    stack = 0x0300_1000
    output = 0x0300_2030
    source = 0x0300_3010

    iwram =
      machine.bus.iwram
      |> Region.write32(stack - 0x0300_0000, 0x0000_4000)
      |> Region.write32(stack - 0x0300_0000 + 4, 0xFFFF_C000)
      |> Region.write32(stack - 0x0300_0000 + 8, 0x0123_4567)
      |> Region.write32(stack - 0x0300_0000 + 12, 0x89AB_CDEF)
      |> Region.write32(stack - 0x0300_0000 + 16, 0x0000_2000)
      |> Region.write32(source - 0x0300_0000, 0x0001_8000)
      |> Region.write32(source - 0x0300_0000 + 4, 0xFFFE_4000)
      |> Region.write32(source - 0x0300_0000 - 8, 0x0000_6000)
      |> Region.write32(source - 0x0300_0000 - 4, 0x0002_2000)
      |> Region.write32(source - 0x0300_0000 - 16, 0xFFFF_0000)
      |> Region.write32(source - 0x0300_0000 - 12, 0x0000_A000)

    bus = %{machine.bus | iwram: iwram}

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(3, output)
      |> put_elem(5, 7)
      |> put_elem(8, 66)
      |> put_elem(9, 0x7FFF)
      |> put_elem(12, source)
      |> put_elem(13, stack)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 134)

    assert {:ok, accelerated_cpu, accelerated_bus, 695} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 136, 300)

    assert accelerated_cpu == scalar_cpu
    accelerated_iwram = Region.to_binary(accelerated_bus.iwram)
    scalar_iwram = Region.to_binary(scalar_bus.iwram)

    differences =
      for index <- 0..(byte_size(accelerated_iwram) - 1),
          :binary.at(accelerated_iwram, index) != :binary.at(scalar_iwram, index),
          do: {index, :binary.at(accelerated_iwram, index), :binary.at(scalar_iwram, index)}

    assert differences == []
    assert accelerated_bus.cycle == scalar_bus.cycle
    assert accelerated_bus == scalar_bus
  end

  test "minimum-record batching matches conditional scalar iterations" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@minimum_record_program), cpu_executor: :scalar)

    table = 0x0300_1000
    records = 0x0200_2000

    iwram =
      Enum.reduce(0..3, machine.bus.iwram, fn index, iwram ->
        Region.write32(iwram, table - 0x0300_0000 + index * 4, records + index * 64)
      end)

    ewram =
      [9, 3, 5, 2]
      |> Enum.with_index()
      |> Enum.reduce(machine.bus.ewram, fn {value, index}, ewram ->
        Region.write(ewram, records - 0x0200_0000 + index * 64 + 54, value)
      end)

    bus = %{machine.bus | iwram: iwram, ewram: ewram}

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(1, table)
      |> put_elem(5, 0xFF)
      |> put_elem(7, 4)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 20)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 22, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
    assert CPU.register(accelerated_cpu, 4) == 3
    assert CPU.register(accelerated_cpu, 5) == 2
  end

  test "byte-fill batching matches scalar memory, registers, and timing" do
    assert {:ok, machine} = Machine.load(TestROM.build(@byte_fill_program), cpu_executor: :scalar)
    base = 0x0300_2000
    limit_address = 0x0300_1000
    iwram = Region.write(machine.bus.iwram, limit_address - 0x0300_0000, 5)
    bus = %{machine.bus | iwram: iwram}

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(1, limit_address)
      |> put_elem(2, 2)
      |> put_elem(4, 0xAA)
      |> put_elem(8, base)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 12)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 14, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus

    assert Region.read_binary(accelerated_bus.iwram, base - 0x0300_0000 + 2, 4) ==
             <<0xAA, 0xAA, 0xAA, 0xAA>>
  end

  test "sparse word-fill batching matches scalar memory, registers, and timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@sparse_word_fill_program), cpu_executor: :scalar)

    destination = 0x0300_2000

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, destination)
      |> put_elem(1, 250)
      |> put_elem(2, 0x1234_5678)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, machine.bus, @target, @target + 8)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, machine.bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, machine.bus, @target + 10, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
    assert Region.read32(accelerated_bus.iwram, destination - 0x0300_0000) == 0x1234_5678
    assert Region.read32(accelerated_bus.iwram, destination - 0x0300_0000 + 16) == 0x1234_5678
  end

  test "sparse word-fill batching preserves Game Pak prefetch timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@sparse_word_fill_program), cpu_executor: :scalar)

    destination = 0x0300_2000

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, destination)
      |> put_elem(1, 250)
      |> put_elem(2, 0x1234_5678)

    bus = Bus.put8(machine.bus, 0x0400_0205, 0x40)
    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 8)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 10, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
  end

  test "sparse halfword-fill batching matches scalar memory, registers, and timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@sparse_halfword_fill_program), cpu_executor: :scalar)

    destination = 0x0300_2000

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, 0x1234)
      |> put_elem(1, destination)
      |> put_elem(2, 4)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, machine.bus, @target, @target + 8)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, machine.bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, machine.bus, @target + 10, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus

    for offset <- [0, 8, 16, 24] do
      assert Region.read16(accelerated_bus.iwram, destination - 0x0300_0000 + offset) ==
               0x1234
    end
  end

  test "strided halfword-fill batching matches scalar memory, registers, and prefetch timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@stride_halfword_fill_program), cpu_executor: :scalar)

    destination = 0x0300_2000
    limit = destination + 4 * 8

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, 0x1234)
      |> put_elem(4, destination)
      |> put_elem(5, limit)

    bus = Bus.put8(machine.bus, 0x0400_0205, 0x40)
    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 6)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 8, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus

    for offset <- [0, 8, 16, 24] do
      assert Region.read16(accelerated_bus.iwram, destination - 0x0300_0000 + offset) ==
               0x1234
    end
  end

  test "backward halfword-copy batching matches scalar memory, registers, and prefetch timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@backward_halfword_copy_program), cpu_executor: :scalar)

    first = 0x0200_2000

    ewram =
      [1, 2, 3, 4]
      |> Enum.with_index()
      |> Enum.reduce(machine.bus.ewram, fn {value, index}, memory ->
        Region.write16(memory, first - 0x0200_0000 + index * 2, value)
      end)

    bus = %{machine.bus | ewram: ewram} |> Bus.put8(0x0400_0205, 0x40)

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(1, first + 6)
      |> put_elem(2, 4)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 10)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 12, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus

    assert Region.read_binary(accelerated_bus.ewram, first - 0x0200_0000, 10) ==
             <<1::little-16, 1::little-16, 2::little-16, 3::little-16, 4::little-16>>
  end

  test "halfword scanning batches only repeated comparisons and preserves scalar timing" do
    data_offset = 0x200

    rom =
      @halfword_scan_program
      |> TestROM.build()
      |> TestROM.put_halfword(data_offset, 1)
      |> TestROM.put_halfword(data_offset + 4, 2)
      |> TestROM.put_halfword(data_offset + 8, 3)
      |> TestROM.put_halfword(data_offset + 12, 0)

    assert {:ok, machine} = Machine.load(rom, cpu_executor: :scalar)
    data = @target + data_offset

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, 10)
      |> put_elem(1, data - 4)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, machine.bus, @target, @target + 10)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, machine.bus)

    {accelerated_cpu, accelerated_bus} =
      run_scalar_until(accelerated_cpu, accelerated_bus, @target + 16, 100)

    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, machine.bus, @target + 16, 100)

    assert accelerated_cpu == scalar_cpu
    assert accelerated_bus == scalar_bus
  end

  test "positive record scanning batches the no-call path with scalar timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@positive_record_scan_program), cpu_executor: :scalar)

    records = 0x0300_2000

    iwram =
      machine.bus.iwram
      |> Region.write32(records - 0x0300_0000, 1)
      |> Region.write32(records - 0x0300_0000 + 0x88, 2)
      |> Region.write32(records - 0x0300_0000 + 0x110, 3)
      |> Region.write32(records - 0x0300_0000 + 0x198, 4)

    bus = %{machine.bus | iwram: iwram}

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(4, records)
      |> put_elem(5, records + 4 * 0x88)

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 16)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 18, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
  end

  test "descending word-fill batching matches early-exit scalar timing and prefetch state" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@descending_word_fill_program), cpu_executor: :scalar)

    destination = 0x0300_2030
    value = 0xFFFE_0000

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(2, destination)
      |> put_elem(3, value)
      |> put_elem(7, 5)

    bus = Bus.put8(machine.bus, 0x0400_0205, 0x40)
    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 20)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 22, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus

    for offset <- [0, 4, 8, 12] do
      assert Region.read32(accelerated_bus.iwram, destination - 0x0300_0000 - offset) == value
    end
  end

  test "empty bucket scanning batches across sparse table entries with scalar timing" do
    assert {:ok, machine} =
             Machine.load(TestROM.build(@empty_bucket_scan_program), cpu_executor: :scalar)

    table = 0x0300_2000

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(0, 124)
      |> put_elem(6, table)

    bus = Bus.put8(machine.bus, 0x0400_0205, 0x40)
    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x3F)
    cpu = ThumbLoop.mark(cpu, bus, @target, @target + 28)

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_until(cpu, bus, @target + 30, 100)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
    assert CPU.register(accelerated_cpu, 0) == 128
    assert CPU.register(accelerated_cpu, 6) == table + 16
  end

  defp run_scalar_steps(cpu, bus, steps) do
    Enum.reduce(1..steps, {cpu, bus}, fn _, {cpu, bus} ->
      {:ok, cpu, bus, _cycles} = CPU.step_scalar(cpu, bus)
      {cpu, bus}
    end)
  end

  defp run_scalar_until(cpu, bus, target, remaining) do
    if CPU.register(cpu, 15) == target do
      {cpu, bus}
    else
      assert remaining > 0
      {:ok, cpu, bus, _cycles} = CPU.step_scalar(cpu, bus)
      run_scalar_until(cpu, bus, target, remaining - 1)
    end
  end

  defp normalize_loop(cpu), do: %{cpu | fast_loop: nil}
end
