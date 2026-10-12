defmodule Beamicom.GBA.SaveStateTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Bus, DiagnosticROM, Machine, SaveState, System}

  test "restores and continues a frame-boundary snapshot exactly" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {machine, [_video, _audio]} = System.run_slice(machine)

    {state, rom_blob} = SaveState.split(machine)

    assert {:ok, %{version: 5, rom: identity}} = SaveState.metadata(state)
    assert identity == SaveState.rom_identity(rom)
    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.bus.cartridge.rom == rom
    assert Machine.block_cache_size(restored) == 0

    {expected_machine, expected_outputs} = System.run_slice(machine)
    {actual_machine, actual_outputs} = System.run_slice(restored)

    assert actual_outputs == expected_outputs
    assert actual_machine == expected_machine
  end

  test "upgrades version-1 PPU state with scanline register defaults" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)
    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()

    legacy_ppu =
      Map.drop(payload.machine.bus.ppu, [
        :bg_affine_internal,
        :bg_affine_dirty,
        :scanline_dispcnt,
        :scanline_bghofs,
        :scanline_bgvofs,
        :scanline_bg_affine,
        :scanline_display_effects
      ])

    legacy_bus =
      payload.machine.bus
      |> Map.drop([:waitcnt, :game_pak_prefetch])
      |> Map.put(:ppu, legacy_ppu)

    legacy_machine = %{payload.machine | bus: legacy_bus}
    legacy_payload = %{payload | version: 1, machine: legacy_machine}

    legacy_state = legacy_payload |> :erlang.term_to_binary() |> :zlib.compress()

    assert {:ok, restored} = SaveState.merge(legacy_state, rom_blob)
    assert elem(restored.bus.ppu.scanline_dispcnt, 0) == restored.bus.ppu.dispcnt
    assert elem(restored.bus.ppu.scanline_bg_affine, 0) == restored.bus.ppu.bg_affine
    assert restored.bus.waitcnt == 0
  end

  test "upgrades version-2 state with the power-on WAITCNT value" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)
    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    legacy_bus = Map.drop(payload.machine.bus, [:waitcnt, :game_pak_prefetch])
    legacy_machine = %{payload.machine | bus: legacy_bus}
    legacy_payload = %{payload | version: 2, machine: legacy_machine}
    legacy_state = legacy_payload |> :erlang.term_to_binary() |> :zlib.compress()

    assert {:ok, restored} = SaveState.merge(legacy_state, rom_blob)
    assert restored.bus.waitcnt == 0
  end

  test "upgrades version-3 state with an empty Game Pak prefetch buffer" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)
    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    legacy_bus = Map.delete(payload.machine.bus, :game_pak_prefetch)
    legacy_machine = %{payload.machine | bus: legacy_bus}
    legacy_payload = %{payload | version: 3, machine: legacy_machine}
    legacy_state = legacy_payload |> :erlang.term_to_binary() |> :zlib.compress()

    assert {:ok, restored} = SaveState.merge(legacy_state, rom_blob)
    assert restored.bus.game_pak_prefetch == {nil, 0, 0}
  end

  test "upgrades version-4 state with silent PSG renderer state" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)
    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()

    legacy_apu =
      payload.machine.bus.apu
      |> Map.put(:soundcnt_l, 0x7700)
      |> Map.put(:soundcnt_h, 0x0302)
      |> Map.put(:soundcnt_x, 0x80)
      |> Map.drop([:psg_registers, :wave_ram, :psg_events, :psg])

    legacy_bus = %{payload.machine.bus | apu: legacy_apu}
    legacy_machine = %{payload.machine | bus: legacy_bus}
    legacy_payload = %{payload | version: 4, machine: legacy_machine}
    legacy_state = legacy_payload |> :erlang.term_to_binary() |> :zlib.compress()

    assert {:ok, restored} = SaveState.merge(legacy_state, rom_blob)
    assert restored.bus.apu.psg.cycle == restored.bus.apu.render_cycle
    assert restored.bus.apu.psg.master
    assert restored.bus.apu.psg.soundcnt_l == 0x7700
    assert restored.bus.apu.psg.soundcnt_h == 0x0302
  end

  test "restores with the current optimized CPU executor" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom, cpu_executor: :decoded_blocks)
    {state, rom_blob} = SaveState.split(machine)

    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.cpu_executor == Machine.default_cpu_executor()
  end

  test "restores an active semantic loop descriptor" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)

    fast_loop = {:byte_compare_poll, 0x0800_0000, 0x0800_0006}
    machine = %{machine | cpu: %{machine.cpu | fast_loop: fast_loop}}
    {state, rom_blob} = SaveState.split(machine)

    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.cpu.fast_loop == fast_loop
  end

  test "restores a snapshot taken between scheduler events" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    bus = Bus.idle(machine.bus, 7)
    machine = %{machine | bus: bus}

    assert bus.scheduler.now < bus.cycle
    {state, rom_blob} = SaveState.split(machine)

    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.bus.cycle == bus.cycle
    assert restored.bus.scheduler == bus.scheduler
  end

  test "rejects corrupt state and mismatched ROM data" do
    rom = DiagnosticROM.loop()
    assert {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)

    assert {:error, :corrupt} = SaveState.merge("not zlib", rom_blob)
    assert {:error, :rom_mismatch} = SaveState.merge(state, :zlib.compress(rom <> <<0>>))

    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    corrupt_payload = put_in(payload.machine.cpu.registers, [])
    corrupt_state = corrupt_payload |> :erlang.term_to_binary() |> :zlib.compress()
    assert {:error, :corrupt} = SaveState.merge(corrupt_state, rom_blob)
  end
end
