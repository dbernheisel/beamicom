defmodule Beamicom.GB.SaveStateTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GB.{Bus, DiagnosticROM, Machine, SaveState, System}
  alias Beamicom.GB.Cartridge
  alias Beamicom.GB.Cartridge.{MBC1, MBC2, MBC3, MBC5}

  test "split/merge restores a machine and continues deterministically" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {machine, _outputs} = System.run_slice(machine)
    {state, rom_blob} = SaveState.split(machine)

    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.bus.cartridge.rom == rom
    assert restored.bus.ppu.frame == :binary.copy(<<255>>, 160 * 144 * 3)
    assert restored.bus.apu.samples == []
    assert restored.bus.apu.sample_count == 0

    {expected_machine, expected_outputs} = System.run_slice(machine)
    {actual_machine, actual_outputs} = System.run_slice(restored)

    assert actual_outputs == expected_outputs
    assert :erlang.term_to_binary(actual_machine) == :erlang.term_to_binary(expected_machine)
  end

  test "split canonicalizes deferred APU time beyond one clock second" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    machine = put_in(machine.bus, Bus.tick(machine.bus, 4_194_305))

    assert machine.bus.apu_pending == 4_194_305

    canonical_apu =
      machine.bus
      |> Bus.sync_apu()
      |> Map.fetch!(:apu)
      |> Map.put(:samples, [])
      |> Map.put(:sample_count, 0)

    canonical =
      machine
      |> put_in([Access.key!(:bus), Access.key!(:apu)], canonical_apu)
      |> put_in([Access.key!(:bus), Access.key!(:apu_pending)], 0)
      |> put_in(
        [Access.key!(:bus), Access.key!(:ppu), Access.key!(:frame)],
        :binary.copy(<<255>>, 160 * 144 * 3)
      )
      |> put_in([Access.key!(:bus), Access.key!(:serial_output)], [])

    {state, rom_blob} = SaveState.split(machine)
    assert {:ok, restored} = SaveState.merge(state, rom_blob)
    assert restored.bus.apu_pending == 0
    assert restored == canonical

    {expected_machine, expected_outputs} = System.run_slice(canonical)
    {actual_machine, actual_outputs} = System.run_slice(restored)

    assert actual_outputs == expected_outputs
    assert actual_machine == expected_machine
  end

  test "rejects a different ROM, corrupt payload, and unsupported version" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {state, rom_blob} = SaveState.split(machine)

    different = :binary.copy(<<0>>, byte_size(rom))
    assert {:error, :rom_mismatch} = SaveState.merge(state, :zlib.compress(different))
    assert {:error, :corrupt} = SaveState.merge("not zlib", rom_blob)

    payload = state |> :zlib.uncompress() |> :erlang.binary_to_term()
    future = payload |> Map.put(:version, 2) |> :erlang.term_to_binary() |> :zlib.compress()
    assert {:error, {:unsupported_version, 2}} = SaveState.merge(future, rom_blob)
  end

  test "bounded inflation rejects small state and ROM bombs" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {state, _rom_blob} = SaveState.split(machine)

    state_bomb = :zlib.compress(:binary.copy(<<0>>, 4 * 1024 * 1024 + 1))
    rom_bomb = :zlib.compress(:binary.copy(<<0>>, 8 * 1024 * 1024 + 1))

    assert byte_size(state_bomb) < 8_000
    assert byte_size(rom_bomb) < 16_000
    assert {:error, :state_too_large} = SaveState.merge(state_bomb, rom_bomb)
    assert {:error, :rom_too_large} = SaveState.merge(state, rom_bomb)
  end

  test "rejects forged execution state before it can reach the emulator" do
    rom = DiagnosticROM.build_cgb()
    {:ok, machine} = Machine.load(rom)
    {machine, _outputs} = System.run_slice(machine)
    {state, rom_blob} = SaveState.split(machine)

    for forge <- [
          &put_in(&1.machine.cpu.a, :running),
          &put_in(&1.machine.cpu.f, 0x0F),
          &put_in(&1.machine.cpu, Map.delete(&1.machine.cpu, :sp)),
          &put_in(&1.machine.bus.wram, {:not, :paged, :memory}),
          &put_in(&1.machine.bus.hdma_request, {:hblank, 1, 0x8000, 129}),
          &put_in(&1.machine.bus.ppu.model, :dmg),
          &put_in(&1.machine.bus.ppu.vram, put_elem(&1.machine.bus.ppu.vram, 0, <<0>>)),
          &put_in(&1.machine.bus.ppu.color_cache, {{<<0, 0>>}, {}}),
          &put_in(&1.machine.bus.apu.pending_dots, 1 <<< 200),
          &put_in(&1.machine.bus.apu.ch4.divisor, 8),
          &put_in(&1.machine.bus.cartridge.header.mapper, :mbc5),
          &put_in(&1.machine.bus.cartridge.ram.pages, {<<0>>})
        ] do
      assert {:error, :corrupt} = SaveState.merge(forge_state(state, forge), rom_blob)
    end
  end

  test "ROM identity includes exact size and SHA-256" do
    assert %{size: 3, sha256: digest} = SaveState.rom_identity(<<1, 2, 3>>)
    assert byte_size(digest) == 32
    refute SaveState.rom_identity(<<1, 2, 3>>) == SaveState.rom_identity(<<1, 2, 4>>)
  end

  test "round-trips every supported mapper struct including MBC3 RTC" do
    cases = [
      {0x00, 0x00, Cartridge, []},
      {0x03, 0x02, MBC1, []},
      {0x06, 0x00, MBC2, []},
      {0x10, 0x02, MBC3, [rtc: %{seconds: 37, days: 123, carry: true}]},
      {0x1B, 0x02, MBC5, []}
    ]

    for {type, ram_size, expected_module, options} <- cases do
      rom = mapper_rom(type, ram_size)
      {:ok, machine} = Machine.load(rom, options)
      assert machine.bus.cartridge.__struct__ == expected_module
      machine = put_in(machine.bus.cartridge, exercise_mapper(machine.bus.cartridge))
      {state, rom_blob} = SaveState.split(machine)
      assert {:ok, restored} = SaveState.merge(state, rom_blob)
      assert restored.bus.cartridge.__struct__ == expected_module
      assert :erlang.term_to_binary(restored) == :erlang.term_to_binary(machine)
    end
  end

  defp mapper_rom(type, ram_size) do
    :binary.copy(<<0>>, 32 * 1024)
    |> put_bytes(0x134, "SAVE MAPPERS" <> :binary.copy(<<0>>, 4))
    |> put_byte(0x143, 0)
    |> put_byte(0x147, type)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, ram_size)
    |> with_checksum()
  end

  defp forge_state(state, forge) do
    state
    |> :zlib.uncompress()
    |> :erlang.binary_to_term()
    |> forge.()
    |> :erlang.term_to_binary()
    |> :zlib.compress()
  end

  defp exercise_mapper(%Cartridge{} = cartridge), do: cartridge

  defp exercise_mapper(%MBC1{} = cartridge) do
    cartridge
    |> Cartridge.write(0x0000, 0x0A)
    |> Cartridge.write(0x2000, 3)
    |> Cartridge.write(0x4000, 1)
    |> Cartridge.write(0x6000, 1)
    |> Cartridge.write(0xA000, 0xA5)
  end

  defp exercise_mapper(%MBC2{} = cartridge) do
    cartridge
    |> Cartridge.write(0x0000, 0x0A)
    |> Cartridge.write(0x2100, 3)
    |> Cartridge.write(0xA000, 0x0B)
  end

  defp exercise_mapper(%MBC3{} = cartridge) do
    cartridge
    |> Cartridge.write(0x0000, 0x0A)
    |> Cartridge.write(0x2000, 3)
    |> Cartridge.write(0x4000, 0x08)
    |> Cartridge.write(0xA000, 42)
    |> Cartridge.write(0x6000, 0)
    |> Cartridge.write(0x6000, 1)
  end

  defp exercise_mapper(%MBC5{} = cartridge) do
    cartridge
    |> Cartridge.write(0x0000, 0x0A)
    |> Cartridge.write(0x2000, 3)
    |> Cartridge.write(0x3000, 1)
    |> Cartridge.write(0x4000, 1)
    |> Cartridge.write(0xA000, 0xA5)
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix_offset = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
  end
end
