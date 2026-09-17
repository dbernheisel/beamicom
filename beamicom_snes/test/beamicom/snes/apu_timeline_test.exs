defmodule Beamicom.SNES.APUTimelineTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{APU, DSP, Machine, SaveState, SPC700}
  alias Beamicom.SNES.DSP.Echo.{Effect, State}

  test "APU advances the DSP's explicit phase on the shared SPC clock" do
    apu = running_apu(spc_ram([{0, 0x00}]))
    apu = APU.advance(apu, 100, :pal)

    assert apu.dsp_cycle_phase == 4
    assert DSP.phase(apu.spc.dsp) == apu.dsp_cycle_phase
  end

  test "DSP writes after phase zero do not change the already-latched sample" do
    {dsp, ram} = audible_voice()
    ram = put_program(ram, [0x8F, 0x0C, 0xF2, 0x8F, 0x00, 0xF3])
    apu = running_apu(ram, dsp)

    apu = APU.advance(apu, 666, :pal)
    assert {1, <<left::signed-little-16, right::signed-little-16>>, apu} = APU.take_pcm(apu)
    assert left != 0
    assert right != 0

    apu = APU.advance(apu, 666, :pal)
    assert {1, <<0::signed-little-16, next_right::signed-little-16>>, _apu} = APU.take_pcm(apu)
    assert next_right != 0
  end

  test "a RAM write after the phase-zero BRR fetch cannot rewrite the current decoded block" do
    ram =
      spc_ram([
        {0, 0xC5},
        {1, 0x01},
        {2, 0x02},
        {0x100, 0x00},
        {0x101, 0x02},
        {0x102, 0x00},
        {0x103, 0x02},
        {0x200, 0xC3}
      ])

    dsp =
      DSP.new()
      |> DSP.write(0x02, 0x00)
      |> DSP.write(0x03, 0x10)
      |> DSP.write(0x04, 0x00)
      |> DSP.write(0x07, 0x7F)
      |> DSP.write(0x5D, 0x01)
      |> DSP.write(0x4C, 0x01)

    spc = %{SPC700.new(ram, 0) | a: 0x77, dsp: dsp}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}
    apu = APU.advance(apu, 666, :pal)

    assert :array.get(0x201, apu.ram) == 0x77
    assert DSP.voice(apu.spc.dsp, 0).buffer == List.duplicate(0, 12) |> List.to_tuple()
  end

  test "accesses from an overdrawn SPC instruction remain pending until their clock" do
    ram = spc_ram([{0, 0xC5}, {1, 0x01}, {2, 0x02}])
    spc = %{SPC700.new(ram, 0) | a: 0x77}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    apu = APU.advance(apu, 21, :pal)
    assert :array.get(0x201, apu.ram) == 0
    assert apu.timeline_events != []

    apu = APU.advance(apu, 83, :pal)
    assert :array.get(0x201, apu.ram) == 0x77
    assert apu.timeline_events == []
    assert apu.spc.access_events == []
    refute apu.spc.capture_access_events?
  end

  test "partial overdraw debt applies MOVW writes at their individual clocks" do
    ram = spc_ram([{0, 0xDA}, {1, 0x20}, {0x20, 0x60}, {0x21, 0x29}])
    spc = %{SPC700.new(ram, 0) | a: 0, y: 5}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    apu = APU.advance(apu, 21, :pal)
    assert :array.get(0x20, apu.ram) == 0x60
    assert :array.get(0x21, apu.ram) == 0x29
    assert length(apu.timeline_events) == 2

    apu = Enum.reduce(1..3, apu, fn _, apu -> APU.advance(apu, 21, :pal) end)
    assert :array.get(0x20, apu.ram) == 0
    assert :array.get(0x21, apu.ram) == 0x29
    assert length(apu.timeline_events) == 1

    apu = APU.advance(apu, 21, :pal)
    assert :array.get(0x21, apu.ram) == 5
    assert apu.timeline_events == []
  end

  test "an SPC DSPDATA read observes live DSP state at its access clock" do
    ram = spc_ram([{0, 0x00}, {1, 0xE4}, {2, 0xF3}])
    dsp = DSP.new()
    voice_pipeline = %{dsp.clock.voice_pipeline | output_latch: 0x5500}
    dsp = put_in(dsp.clock.voice_pipeline, voice_pipeline)
    spc = %{SPC700.new(ram, 0) | dsp: dsp, dsp_addr: 0x09}
    initial = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    # Three paid clocks execute the two-clock NOP, then speculatively complete
    # the following instruction whose DSPDATA access occurs at clock five.
    apu = APU.advance(initial, 63, :pal)

    assert apu.spc.cycle_credit == -2
    assert apu.spc.a == 0x55
    assert DSP.phase(apu.spc.dsp) == 3

    batched = APU.advance(initial, 2_100, :pal)
    partitioned = APU.advance(apu, 2_037, :pal)
    assert drained(partitioned) == drained(batched)
  end

  test "an SPC RAM read observes an earlier DSP echo write" do
    ram = spc_ram([{0, 0xE5}, {1, 0x00}, {2, 0x02}])

    effect = %Effect{
      operation: :write,
      phase: 29,
      channel: :left,
      address: 0x0200,
      value: 0x1234
    }

    dsp = DSP.new()

    clock = %{
      dsp.clock
      | phase: 29,
        echo_pending_state: %State{},
        echo_write_effects: [effect],
        echo_flg_28: 0
    }

    dsp = %{dsp | clock: clock}
    spc = %{SPC700.new(ram, 0) | dsp: dsp}

    apu = %{
      APU.new()
      | ram: ram,
        spc: spc,
        ipl_state: :running,
        dsp_cycle_phase: 29
    }

    apu = APU.advance(apu, 42, :pal)

    assert apu.spc.cycle_credit == -2
    assert apu.spc.a == 0x34
    assert :array.get(0x0200, apu.ram) == 0x34
    assert :array.get(0x0201, apu.ram) == 0x12
  end

  test "arbitrary master-clock partitions preserve APU state, ports, RAM, and PCM" do
    {dsp, ram} = audible_voice()
    ram = put_program(ram, [0x8F, 0x0C, 0xF2, 0x8F, 0x00, 0xF3, 0x00])
    initial = running_apu(ram, dsp)
    total = 20_000

    batched = APU.advance(initial, total, :pal)

    partitioned =
      [1, 7, 31, 666, 3_001, total - 3_706]
      |> Enum.reduce(initial, fn clocks, apu -> APU.advance(apu, clocks, :pal) end)

    assert drained(partitioned) == drained(batched)
  end

  test "save state resumes identically from every DSP phase" do
    rom = Beamicom.SNESTestROM.build(:lorom, program: <<0xEA, 0x80, 0xFD>>)
    {:ok, machine} = Machine.load(rom)
    ram = spc_ram([{0, 0x00}])

    for phase <- 0..31 do
      {dsp, _pcm} = DSP.clock(DSP.new(), ram, phase)
      spc = %{SPC700.new(ram, 0) | dsp: dsp}
      apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running, dsp_cycle_phase: phase}
      phased = put_in(machine.bus.apu, apu)
      {state, rom_blob} = SaveState.split(phased)

      assert {:ok, restored} = SaveState.merge(state, rom_blob)
      assert restored.bus.apu.spc.dsp == dsp
      assert restored.bus.apu.dsp_cycle_phase == phase

      {expected, expected_pcm} = DSP.clock(dsp, ram, 65)
      {actual, actual_pcm} = DSP.clock(restored.bus.apu.spc.dsp, ram, 65)
      assert {actual, actual_pcm} == {expected, expected_pcm}
    end
  end

  defp running_apu(ram, dsp \\ DSP.new()) do
    spc = %{SPC700.new(ram, 0) | dsp: dsp}
    %{APU.new() | ram: ram, spc: spc, ipl_state: :running}
  end

  defp audible_voice do
    ram =
      spc_ram([
        {0x100, 0x00},
        {0x101, 0x02},
        {0x102, 0x00},
        {0x103, 0x02},
        {0x200, 0xC3}
      ])
      |> then(fn ram ->
        Enum.reduce(0x201..0x208, ram, fn address, ram -> :array.set(address, 0x77, ram) end)
      end)

    dsp =
      DSP.new()
      |> DSP.write(0x00, 0x7F)
      |> DSP.write(0x01, 0x7F)
      |> DSP.write(0x02, 0x00)
      |> DSP.write(0x03, 0x10)
      |> DSP.write(0x04, 0x00)
      |> DSP.write(0x07, 0x7F)
      |> DSP.write(0x0C, 0x7F)
      |> DSP.write(0x1C, 0x7F)
      |> DSP.write(0x5D, 0x01)
      |> DSP.write(0x4C, 0x01)

    {dsp, _startup} = DSP.render(dsp, ram, 8)
    {dsp, ram}
  end

  defp put_program(ram, bytes) do
    bytes
    |> Enum.with_index()
    |> Enum.reduce(ram, fn {value, address}, ram -> :array.set(address, value, ram) end)
  end

  defp spc_ram(bytes) do
    Enum.reduce(bytes, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value &&& 0xFF, ram)
    end)
  end

  defp drained(apu) do
    {frames, pcm, apu} = APU.drain_pcm(apu)
    {spc_cycles, apu} = APU.take_spc_cycles(apu)
    {frames, pcm, spc_cycles, apu}
  end
end
