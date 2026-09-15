defmodule Beamicom.NES.Recompiler.MMC5Test do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Bus, CPU, Cart, Console, Mapper}
  alias Beamicom.NES.Recompiler.{Equivalence, Generator, MMC5Profile, Program, Semantics}

  test "profiles bank changes and dispatches blocks by PC plus MMC5 mapping" do
    cart = fixture_cart()
    start = console(cart)

    assert {:ok, profile, _after_profile} = MMC5Profile.capture(start, 5)
    assert MapSet.size(profile.signatures) == 2
    assert profile.mapping_changes == 1

    assert {:ok, program} = Generator.compile(cart, profile)
    assert map_size(program.discovery.instructions) >= 5
    assert Enum.all?(program.module.block_starts(), &match?({{{_, _, _, _}, _}, _}, &1))

    assert {:ok, result} =
             Equivalence.compare_many(start, fn state -> Program.step(program, state) end, 3)

    assert result.cpu.x == 1
    assert result.bus.prg_banks == {0x8000, 0x2000, 0x4000, 0xE000}

    stats = Program.statistics(program)
    assert stats.compiled_blocks == 3
    assert stats.compiled_instructions == 5
    assert stats.fallback_instructions == 0

    assert %{
             lowered_instruction_identities: 5,
             instruction_identities: 5,
             identity_percent: 100.0,
             lowered_profile_hits: 5,
             profile_hits: 5,
             profile_hit_percent: 100.0
           } = Semantics.coverage(program.discovery)
  end

  test "an executable PRG-RAM window is always an interpreter fallback" do
    cart = fixture_cart()
    start = console(cart)
    assert {:ok, profile, _} = MMC5Profile.capture(start, 5)
    assert {:ok, program} = Generator.compile(cart, profile)

    ram_mapping =
      start
      |> put_in(
        [Access.key!(:bus), Access.key!(:mapper_state), Access.key!(:m5_prg_regs)],
        {0, 0x04, 0x81, 0x82, 0xFF}
      )
      |> then(fn console -> %{console | bus: Mapper.reset(console.bus)} end)
      |> put_in([Access.key!(:cpu), Access.key!(:pc)], 0x8000)

    refute program.module.known_console?(ram_mapping)

    assert {:ok, _result} =
             Equivalence.compare(ram_mapping, fn state -> Program.step(program, state) end)

    assert Program.statistics(program).fallback_instructions == 1
  end

  defp fixture_cart do
    prg =
      :binary.copy(<<0xEA>>, 0x10000)
      # LDA #$84; STA $5114; JMP $8000 in the fixed final bank.
      |> put_physical(0xE100, <<0xA9, 0x84, 0x8D, 0x14, 0x51, 0x4C, 0x00, 0x80>>)
      # Bank 4 becomes visible at $8000 after the $5114 write.
      |> put_physical(0x8000, <<0xE8, 0x60>>)
      |> put_physical(0xFFFA, <<0x00, 0xE1, 0x00, 0xE1, 0x00, 0xE1>>)

    %Cart{mapper: 5, submapper: 0, prg_rom: prg, chr_rom: <<>>, prg_ram_size: 0x10000}
  end

  defp console(cart) do
    bus = cart |> Bus.new(nil) |> Mapper.reset()
    %Console{cpu: CPU.reset(bus), bus: bus}
  end

  defp put_physical(prg, offset, bytes) do
    tail = offset + byte_size(bytes)
    binary_part(prg, 0, offset) <> bytes <> binary_part(prg, tail, byte_size(prg) - tail)
  end
end
