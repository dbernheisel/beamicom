defmodule Beamicom.NES.SaveStateTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Console, SaveState}

  @nestest "test/support/fixtures/nestest.nes"

  defp loaded_console do
    c = Console.load(@nestest)
    Enum.reduce(1..100_000, c, fn _, acc -> Console.step(acc) end)
  end

  test "split/merge round-trips to byte-identical console" do
    c = loaded_console()
    {state_bin, rom_blob} = SaveState.split(c)
    assert {:ok, c2} = SaveState.merge(state_bin, rom_blob)
    assert :erlang.term_to_binary(c) == :erlang.term_to_binary(c2)
  end

  test "split zeroes out prg and chr in the saved state_bin" do
    c = loaded_console()
    {state_bin, _rom_blob} = SaveState.split(c)
    %{console: stripped} = :erlang.binary_to_term(:zlib.uncompress(state_bin))
    assert stripped.bus.prg == <<>>
    assert stripped.bus.ppu.chr == <<>>
  end

  test "merge rejects CRC mismatch (valid save data paired with wrong ROM)" do
    c = loaded_console()
    {state_bin, _rom_blob} = SaveState.split(c)
    # A validly-compressed but wrong ROM: decompresses fine, fails the CRC check.
    bad_blob = :zlib.compress(:erlang.term_to_binary({<<0, 1, 2, 3>>, <<4, 5, 6, 7>>}))
    assert {:error, :crc_mismatch} = SaveState.merge(state_bin, bad_blob)
  end

  test "merge rejects foreign binary safely" do
    assert {:error, _} = SaveState.merge(<<"garbage">>, <<"garbage">>)
  end

  test "rom_crc/1 returns same crc as split/1" do
    c = Console.load(@nestest)
    {state_bin, _} = SaveState.split(c)
    %{rom_crc: saved_crc} = :erlang.binary_to_term(:zlib.uncompress(state_bin))
    assert SaveState.rom_crc(@nestest) == saved_crc
  end
end
