defmodule Beamicom.GBA.CPU.ArmLoopTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{CPU, Machine, TestROM}
  alias Beamicom.GBA.CPU.BlockCache
  alias Beamicom.GBA.Memory.Region

  @target 0x0300_2894
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

  test "affine loop acceleration is exact for CPU, memory, and timing" do
    rom =
      TestROM.build()
      |> TestROM.put_byte(0x201, 0xB5)
      |> TestROM.put_byte(0x202, 0xD6)
      |> TestROM.put_byte(0x203, 0x27)
      |> TestROM.put_byte(0x204, 0x38)
      |> TestROM.put_byte(0x205, 0x24)

    assert {:ok, machine} = Machine.load(rom, cpu_executor: :decoded_blocks)

    registers =
      {51, 0xFFFF_FFE3, 1_914, 0x0800_0200, 9_975_000, 0x0300_60A0, 17, 0x0300_6200, 176, 85,
       2_293_760, 0, 798, 0x0300_7FD8, 2_750_080, 0}

    cpu = CPU.new(registers: registers, pc: @target, cpsr: 0x1F)
    code = for opcode <- @code, into: <<>>, do: <<opcode::little-32>>

    iwram =
      machine.bus.iwram
      |> Region.write_binary(@target - 0x0300_0000, code)
      |> Region.write32(0x60A0, 17)

    bus = %{machine.bus | iwram: iwram}
    {block, _cache} = BlockCache.fetch(machine.block_cache, cpu, bus)

    assert block.accelerator == {:affine_quad, 0}

    assert {:ok, accelerated_cpu, accelerated_bus, 76} =
             CPU.run_cached_block(cpu, bus, block, bus.ppu.frame_number, 76)

    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 76)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
  end

  test "IWRAM blocks are replaced when their code page changes" do
    assert {:ok, machine} = Machine.load(TestROM.build(), cpu_executor: :decoded_blocks)
    cpu = CPU.new(pc: 0x0300_0000, cpsr: 0x1F)
    bus = %{machine.bus | iwram: Region.write32(machine.bus.iwram, 0, 0xE3A0_0001)}

    {first, cache} = BlockCache.fetch(machine.block_cache, cpu, bus)
    bus = %{bus | iwram: Region.write32(bus.iwram, 0, 0xE3A0_0002)}
    {second, cache} = BlockCache.fetch(cache, cpu, bus)

    assert elem(elem(first.instructions, 0), 0) == 0xE3A0_0001
    assert elem(elem(second.instructions, 0), 0) == 0xE3A0_0002
    assert BlockCache.size(cache) == 1
  end

  test "affine inner-loop acceleration is exact for CPU and timing" do
    rom =
      TestROM.build()
      |> TestROM.put_byte(0x201, 0xB5)
      |> TestROM.put_byte(0x202, 0xD6)
      |> TestROM.put_byte(0x203, 0x27)
      |> TestROM.put_byte(0x204, 0x38)
      |> TestROM.put_byte(0x205, 0x24)

    assert {:ok, machine} = Machine.load(rom, cpu_executor: :scalar)

    registers =
      {51, 0xFFFF_FFE3, 1_914, 0x0800_0200, 9_975_000, 0x0300_60A0, 17, 0x0300_6200, 176, 85,
       2_293_760, 0, 798, 0x0300_7FD8, 2_750_080, 0}

    code = for opcode <- @code, into: <<>>, do: <<opcode::little-32>>
    inner_target = @target + 4
    inner_branch = @target + 18 * 4
    iwram = Region.write_binary(machine.bus.iwram, @target - 0x0300_0000, code)
    bus = %{machine.bus | iwram: iwram}
    cpu = CPU.new(registers: registers, pc: inner_target, cpsr: 0x1F)
    cpu = %{cpu | run_state: {:interrupt_wait_irq, 1, 0x0800_0000, cpu.cpsr}}
    {cpu, bus} = run_scalar_steps(cpu, bus, 18)

    assert cpu.pc == inner_target
    assert cpu.fast_loop == {:arm_affine_inner, inner_target, inner_branch}

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 54)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
  end

  test "affine outer descriptor accelerates and remains across the nested inner loop" do
    assert {:ok, machine} = Machine.load(TestROM.build(), cpu_executor: :scalar)

    registers =
      {51, 0xFFFF_FFE3, 1_914, 0x0800_0200, 9_975_000, 0x0300_60A0, 17, 0x0300_6200, 176, 85,
       2_293_760, 0, 798, 0x0300_7FD8, 2_750_080, 0}

    code = for opcode <- @code, into: <<>>, do: <<opcode::little-32>>
    inner_target = @target + 4
    iwram = Region.write_binary(machine.bus.iwram, @target - 0x0300_0000, code)
    bus = %{machine.bus | iwram: iwram}

    cpu = CPU.new(registers: registers, pc: inner_target, cpsr: 0x1F)
    cpu = %{cpu | fast_loop: {:arm_affine_quad, @target, @target + 21 * 4}}

    assert {:ok, accelerated_cpu, accelerated_bus, _cycles} = CPU.step(cpu, bus)
    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 72)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
    assert accelerated_cpu.fast_loop == {:arm_affine_quad, @target, @target + 21 * 4}
  end

  test "signed-byte mixing acceleration is exact for CPU, memory, and timing" do
    assert {:ok, machine} = Machine.load(TestROM.build(), cpu_executor: :decoded_blocks)
    target = 0x0300_2000
    destination = 0x0300_3000
    source = 0x0300_3100
    code = for opcode <- @signed_byte_mix_code, into: <<>>, do: <<opcode::little-32>>

    iwram =
      machine.bus.iwram
      |> Region.write_binary(target - 0x0300_0000, code)
      |> Region.write_binary(destination - 0x0300_0000, <<0x80, 0x7F, 0x10, 0xF0, 1, 2, 3, 4>>)
      |> Region.write_binary(source - 0x0300_0000, <<0xFF, 1, 0x80, 0x7F, 8, 7, 6, 5>>)

    registers =
      List.duplicate(0, 16)
      |> List.to_tuple()
      |> put_elem(3, 20)
      |> put_elem(4, 8)
      |> put_elem(5, destination)
      |> put_elem(7, source)

    cpu = CPU.new(registers: registers, pc: target, cpsr: 0x1F)
    bus = %{machine.bus | iwram: iwram}
    {block, _cache} = BlockCache.fetch(machine.block_cache, cpu, bus)

    assert block.accelerator == {:signed_byte_mix, 0}

    assert {:ok, accelerated_cpu, accelerated_bus, 80} =
             CPU.run_cached_block(cpu, bus, block, bus.ppu.frame_number, 80)

    {scalar_cpu, scalar_bus} = run_scalar_steps(cpu, bus, 80)

    assert normalize_loop(accelerated_cpu) == normalize_loop(scalar_cpu)
    assert accelerated_bus == scalar_bus
  end

  defp run_scalar_steps(cpu, bus, steps) do
    Enum.reduce(1..steps, {cpu, bus}, fn _, {cpu, bus} ->
      {:ok, cpu, bus, _cycles} = CPU.step_scalar(cpu, bus)
      {cpu, bus}
    end)
  end

  defp normalize_loop(cpu), do: %{cpu | fast_loop: nil}
end
