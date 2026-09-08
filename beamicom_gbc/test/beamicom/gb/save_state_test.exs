defmodule Beamicom.GB.SaveStateTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GB.{DiagnosticROM, Machine, SaveState, System}
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
