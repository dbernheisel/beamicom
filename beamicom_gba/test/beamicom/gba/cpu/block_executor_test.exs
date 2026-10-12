defmodule Beamicom.GBA.CPU.BlockExecutorTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{CPU, Machine, TestROM}
  alias Beamicom.GBA.CPU.BlockCache

  test "cached ARM execution is exact through memory and control-flow exits" do
    program =
      <<
        0xE3A0_0001::little-32,
        0xE280_1002::little-32,
        0xE3A0_2402::little-32,
        0xE582_1000::little-32,
        0xEAFF_FFFE::little-32
      >>

    assert {:ok, scalar} = Machine.load(TestROM.build(program), cpu_executor: :scalar)
    assert {:ok, cached} = Machine.load(TestROM.build(program), cpu_executor: :decoded_blocks)

    {block, cache} = BlockCache.fetch(cached.block_cache, cached.cpu, cached.bus.cartridge)
    assert BlockCache.size(cache) == 1
    assert {^block, ^cache} = BlockCache.fetch(cache, cached.cpu, cached.bus.cartridge)

    target_frame = cached.bus.ppu.frame_number

    assert {:ok, cached_cpu, cached_bus, 5} =
             CPU.run_cached_block(cached.cpu, cached.bus, block, target_frame, 5)

    {scalar_cpu, scalar_bus} = run_scalar_steps(scalar.cpu, scalar.bus, 5)
    assert cached_cpu == scalar_cpu
    assert cached_bus == scalar_bus
  end

  test "cached Thumb execution is exact across an ARM exchange" do
    program =
      <<
        0xE12F_FF10::little-32,
        0x2005::little-16,
        0x3003::little-16,
        0x6008::little-16,
        0xE7FE::little-16
      >>

    assert {:ok, scalar} = Machine.load(TestROM.build(program), cpu_executor: :scalar)
    assert {:ok, cached} = Machine.load(TestROM.build(program), cpu_executor: :decoded_blocks)

    scalar_cpu =
      scalar.cpu
      |> CPU.put_register(0, 0x0800_0005)
      |> CPU.put_register(1, 0x0200_0000)

    cached_cpu =
      cached.cpu
      |> CPU.put_register(0, 0x0800_0005)
      |> CPU.put_register(1, 0x0200_0000)

    {:ok, scalar_cpu, scalar_bus, _cycles} = CPU.step(scalar_cpu, scalar.bus)
    {:ok, cached_cpu, cached_bus, _cycles} = CPU.step(cached_cpu, cached.bus)
    cached = %{cached | cpu: cached_cpu, bus: cached_bus}

    {block, _cache} = BlockCache.fetch(cached.block_cache, cached.cpu, cached.bus.cartridge)
    target_frame = cached.bus.ppu.frame_number

    assert {:ok, cached_cpu, cached_bus, 4} =
             CPU.run_cached_block(cached.cpu, cached.bus, block, target_frame, 4)

    {scalar_cpu, scalar_bus} = run_scalar_steps(scalar_cpu, scalar_bus, 4)
    assert cached_cpu == scalar_cpu
    assert cached_bus == scalar_bus
  end

  test "decoded and scalar frame paths produce identical machine truth" do
    rom = TestROM.build()
    assert {:ok, scalar} = Machine.load(rom, cpu_executor: :scalar)
    assert {:ok, cached} = Machine.load(rom, cpu_executor: :decoded_blocks)

    assert {:ok, scalar, scalar_number, scalar_frame, scalar_samples, scalar_pcm} =
             Machine.run_until_frame(scalar)

    assert {:ok, cached, cached_number, cached_frame, cached_samples, cached_pcm} =
             Machine.run_until_frame(cached)

    assert cached_number == scalar_number
    assert cached_frame == scalar_frame
    assert cached_samples == scalar_samples
    assert cached_pcm == scalar_pcm
    assert cached.cpu == scalar.cpu
    assert cached.bus == scalar.bus
    assert cached.audio_phase == scalar.audio_phase
    assert Machine.block_cache_size(cached) > 0
  end

  defp run_scalar_steps(cpu, bus, steps) do
    Enum.reduce(1..steps, {cpu, bus}, fn _, {cpu, bus} ->
      {:ok, cpu, bus, _cycles} = CPU.step(cpu, bus)
      {cpu, bus}
    end)
  end
end
