defmodule Beamicom.SNES.SaveStateTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, Bus, DSP, Machine, PPU, SA1, SaveState, SPC700, SuperFX}

  test "split and merge restore deterministic execution without transient output" do
    rom = Beamicom.SNESTestROM.build(:lorom, program: <<0xEA, 0x80, 0xFD>>)
    {:ok, machine} = Machine.load(rom)
    machine = run_steps(machine, 100)
    machine = put_in(machine.bus.ppu.frame_ready, %{data: "transient"})
    machine = put_in(machine.bus.ppu.cached_frame_data, "cached")
    machine = put_in(machine.bus.wrio, 0x5A)
    machine = put_in(machine.bus.ppu.latched_hcounter, 0x12C)
    machine = put_in(machine.bus.ppu.latched_vcounter, 0x102)
    machine = put_in(machine.bus.ppu.hcounter_second_byte?, true)
    machine = put_in(machine.bus.ppu.vcounter_second_byte?, true)
    machine = put_in(machine.bus.ppu.counter_latched?, true)
    machine = put_in(machine.bus.ppu.ppu1_mdr, 0xA5)
    machine = put_in(machine.bus.ppu.ppu2_mdr, 0x5A)
    machine = put_in(machine.bus.ppu.obj_range_over?, true)
    machine = put_in(machine.bus.ppu.obj_time_over?, true)
    machine = put_in(machine.bus.ppu.obj_interlace?, true)
    machine = put_in(machine.bus.ppu.pseudo_hires?, true)
    machine = put_in(machine.bus.ppu.interlace_field, 1)
    machine = put_in(machine.bus, Bus.put_open_bus(machine.bus, 0xC3))
    machine = put_in(machine.bus, Bus.put_cpu_pending_clocks(machine.bus, 24))
    previous_ppu = machine.bus.ppu
    changed_ppu = PPU.write(previous_ppu, 0x2100, 0x0F)
    ppu = PPU.capture_raster_change(previous_ppu, changed_ppu, 5, 88 + 40 * 4)
    machine = put_in(machine.bus.ppu, ppu)

    {state, rom_blob} = SaveState.split(machine)

    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    assert payload.version == 4
    assert byte_size(payload.machine.bus.apu.ram) == 0x10000
    assert payload.machine.bus.apu.spc.ram == payload.machine.bus.apu.ram

    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.cartridge.rom == rom
    assert restored.bus.cartridge == restored.cartridge
    assert restored.bus.ppu.frame_ready == nil
    assert restored.bus.ppu.cached_frame_data == nil
    assert restored.bus.ppu.render_task == nil
    assert restored.bus.apu.pending_pcm == []
    assert APU.RAM.valid?(restored.bus.apu.ram)
    assert restored.bus.apu.spc.ram == restored.bus.apu.ram
    assert restored.bus.wrio == 0x5A
    assert restored.bus.ppu.latched_hcounter == 0x12C
    assert restored.bus.ppu.latched_vcounter == 0x102
    assert restored.bus.ppu.hcounter_second_byte?
    assert restored.bus.ppu.vcounter_second_byte?
    assert restored.bus.ppu.counter_latched?
    assert restored.bus.ppu.ppu1_mdr == 0xA5
    assert restored.bus.ppu.ppu2_mdr == 0x5A
    assert restored.bus.ppu.obj_range_over?
    assert restored.bus.ppu.obj_time_over?
    assert restored.bus.ppu.obj_interlace?
    assert restored.bus.ppu.pseudo_hires?
    assert restored.bus.ppu.interlace_field == 1
    assert restored.bus.ppu.raster_segments == machine.bus.ppu.raster_segments
    assert Bus.open_bus(restored.bus) == 0xC3
    assert Bus.cpu_pending_clocks(restored.bus) == 24

    {:ok, expected, _clocks} = Machine.step(machine)
    {:ok, actual, _clocks} = Machine.step(restored)
    assert normalize_transient(actual) == normalize_transient(expected)
  end

  test "rejects mismatched ROMs, corrupt state, and unsupported versions" do
    rom = Beamicom.SNESTestROM.build(:lorom)
    {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)

    different = Beamicom.SNESTestROM.build(:lorom, title: "DIFFERENT SNES ROM")
    assert {:error, :rom_mismatch} = SaveState.merge(state, :zlib.compress(different))
    assert {:error, :corrupt} = SaveState.merge("not zlib", rom_blob)

    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    future = payload |> Map.put(:version, 5) |> :erlang.term_to_binary() |> :zlib.compress()
    assert {:error, {:unsupported_version, 5}} = SaveState.merge(future, rom_blob)
  end

  test "rejects malformed execution structures before resuming the emulator" do
    rom = Beamicom.SNESTestROM.build(:lorom)
    {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)

    for forge <- [
          &put_in(&1.machine.cpu.a, :invalid),
          &put_in(&1.machine.bus.wram, :not_an_array),
          &put_in(&1.machine.bus.ppu.vram, :not_an_array),
          &put_in(&1.machine.bus.ppu.cgram_write_latch, :not_a_byte),
          &put_in(&1.machine.bus.ppu.ppu1_mdr, 0x100),
          &put_in(&1.machine.bus.ppu.cgram_second_byte?, :not_a_boolean),
          &put_in(&1.machine.bus.apu.pending_pcm, ["forged output"]),
          &put_in(&1.machine.bus.apu.timeline_events, [
            {2, :ram_write, 0, 0},
            {1, :ram_write, 0, 0}
          ]),
          &put_in(
            &1.machine.bus.apu.timeline_events,
            List.duplicate({1, :ram_write, 0, 0}, APU.timeline_event_limit() + 1)
          ),
          &put_in(&1.machine.bus.apu.spc.access_events, [{1, :ram_write, 0, 0}]),
          &put_in(&1.machine.bus.apu.spc.capture_access_events?, true),
          &put_in(&1.machine.bus.apu.spc.dsp.registers, {0}),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.registers, {0}),
          &put_in(&1.machine.bus.apu.spc.test, 0x100),
          &put_in(&1.machine.bus.apu.spc.sleeping?, :not_a_boolean),
          fn payload ->
            spc = %{payload.machine.bus.apu.spc | sleeping?: true, stopped?: true}
            put_in(payload.machine.bus.apu.spc, spc)
          end,
          &put_in(&1.machine.bus.apu.apu_renderer, :not_a_renderer),
          fn payload ->
            update_in(payload.machine.bus.apu.spc.dsp.clock.voice_pipeline.voices, fn voices ->
              voice = elem(voices, 0) |> Map.put(:active?, :not_a_boolean)
              put_elem(voices, 0, voice)
            end)
          end,
          fn payload ->
            update_in(payload.machine.bus.apu.spc.dsp.clock.voice_pipeline.voices, fn voices ->
              voice = elem(voices, 0) |> Map.put(:buffer, {0})
              put_elem(voices, 0, voice)
            end)
          end,
          &put_in(&1.machine.bus.apu.spc.dsp.clock.pipeline.completed_voices, 0x100),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.pipeline.main_bus, {:invalid, 0}),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.noise.lfsr, 0x8000),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.noise.counter, 30_720),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.noise.sample, :not_a_sample),
          &put_in(&1.machine.bus.apu.spc.dsp.clock.phase, 32),
          &put_in(&1.machine.bus.dma_channels, {})
        ] do
      payload = state |> :zlib.uncompress() |> :erlang.binary_to_term() |> forge.()
      forged = payload |> :erlang.term_to_binary() |> :zlib.compress()
      assert {:error, :corrupt} = SaveState.merge(forged, rom_blob)
    end
  end

  test "preserves ordered pending APU events and DSP phase across save and restore" do
    rom = Beamicom.SNESTestROM.build(:lorom, program: <<0xEA, 0x80, 0xFD>>)
    {:ok, machine} = Machine.load(rom)

    ram =
      [{0, 0x8F}, {1, 0x55}, {2, 0xF3}]
      |> Enum.reduce(:array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
        :array.set(address, value, ram)
      end)

    spc = %{SPC700.new(ram, 0) | dsp_addr: 0x0C}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}
    snapshot = apu |> APU.advance(21, :pal) |> APU.snapshot()

    assert snapshot.timeline_events == [
             {5, :ram_write, 0xF3, 0x55},
             {5, :dsp_write, 0x0C, 0x55}
           ]

    assert DSP.phase(snapshot.spc.dsp) == snapshot.dsp_cycle_phase

    machine = put_in(machine.bus.apu, snapshot)
    {state, rom_blob} = SaveState.split(machine)
    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    restored_apu = restored.bus.apu

    assert restored_apu.timeline_events == snapshot.timeline_events
    assert restored_apu.dsp_cycle_phase == snapshot.dsp_cycle_phase

    expected = APU.advance(snapshot, 83, :pal)
    actual = APU.advance(restored_apu, 83, :pal)

    assert actual.timeline_events == []
    assert APU.RAM.get(actual.ram, 0xF3) == 0x55
    assert DSP.read(actual.spc.dsp, 0x0C) == 0x55
    assert canonical_apu(actual) == canonical_apu(expected)
  end

  test "round-trips pending phase-timed echo state and RAM effects" do
    rom = Beamicom.SNESTestROM.build(:lorom)
    {:ok, machine} = Machine.load(rom)

    ram =
      :array.new(0x10000, default: 0, fixed: true)
      |> then(&:array.set(0x2000, 0x00, &1))
      |> then(&:array.set(0x2001, 0x20, &1))
      |> then(&:array.set(0x2002, 0x00, &1))
      |> then(&:array.set(0x2003, 0xE0, &1))

    dsp =
      DSP.new()
      |> DSP.write(0x2C, 0x7F)
      |> DSP.write(0x3C, 0x7F)
      |> DSP.write(0x0D, 0x7F)
      |> DSP.write(0x6D, 0x20)
      |> DSP.write(0x7D, 0x01)
      |> DSP.write(0x7F, 0x7F)

    {dsp, ram, <<>>} = DSP.clock_ram(dsp, ram, 24)
    assert DSP.phase(dsp) == 24
    assert %DSP.Echo.State{} = dsp.clock.echo_pending_state

    spc = %{SPC700.new(ram, 0) | dsp: dsp}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running, dsp_cycle_phase: 24}
    machine = put_in(machine.bus.apu, apu)

    {state, rom_blob} = SaveState.split(machine)
    assert {:ok, restored} = SaveState.merge(state, rom_blob)

    restored_apu = restored.bus.apu
    assert restored_apu.spc.dsp.clock == dsp.clock

    {actual_dsp, actual_ram, actual_pcm} =
      DSP.clock_ram(restored_apu.spc.dsp, restored_apu.spc.ram, 8)

    {expected_dsp, expected_ram, expected_pcm} = DSP.clock_ram(dsp, ram, 8)

    assert actual_dsp == expected_dsp
    assert actual_pcm == expected_pcm
    assert APU.RAM.to_binary(actual_ram) == APU.RAM.to_binary(expected_ram)
  end

  test "round-trips atomics-backed SuperFX and SA-1 coprocessor memory" do
    super_fx_rom =
      Beamicom.SNESTestROM.build(:lorom,
        cartridge_type: 0x13,
        expansion_ram_size_code: 5
      )

    {:ok, super_fx_machine} = Machine.load(super_fx_rom)
    assert %SuperFX{} = super_fx_machine.bus.coprocessor
    {state, rom_blob} = SaveState.split(super_fx_machine)

    assert {:ok, %{bus: %{coprocessor: %SuperFX{} = restored_super_fx}}} =
             SaveState.merge(state, rom_blob)

    assert :atomics.info(restored_super_fx.ram).size == restored_super_fx.ram_size
    assert :atomics.get(restored_super_fx.ram, 1) == 0xFF

    sa1_rom =
      Beamicom.SNESTestROM.build(:lorom,
        map_mode: 0x23,
        cartridge_type: 0x34,
        ram_size_code: 5
      )

    {:ok, sa1_machine} = Machine.load(sa1_rom)
    assert %SA1{} = sa1_machine.bus.coprocessor
    {state, rom_blob} = SaveState.split(sa1_machine)

    assert {:ok, %{bus: %{coprocessor: %SA1{} = restored_sa1}}} =
             SaveState.merge(state, rom_blob)

    assert :atomics.info(restored_sa1.iram).size == 0x800
    assert :atomics.info(restored_sa1.bwram).size == restored_sa1.bwram_size
  end

  defp run_steps(machine, count) do
    Enum.reduce(1..count, machine, fn _step, machine ->
      {:ok, machine, _clocks} = Machine.step(machine)
      machine
    end)
  end

  defp normalize_transient(machine) do
    ppu = %{
      machine.bus.ppu
      | cache_identity: nil,
        frame_ready: nil,
        cached_render_key: nil,
        cached_frame_data: nil,
        cached_frame_height: nil,
        render_dirty?: true,
        render_task: nil
    }

    apu =
      machine.bus.apu
      |> Map.merge(%{pending_frames: 0, pending_pcm: [], pending_spc_cycles: 0})
      |> canonical_apu()

    bus = %{machine.bus | runtime: Bus.serialized_runtime(machine.bus), ppu: ppu, apu: apu}
    %{machine | bus: bus}
  end

  defp canonical_apu(apu) do
    ram = APU.RAM.to_binary(apu.ram)
    spc = if apu.spc, do: %{apu.spc | ram: ram}, else: nil
    %{apu | ram: ram, spc: spc}
  end
end
