defmodule Beamicom.NES.Recompiler.GeneratorTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.NES.{Bus, CPU, Cart, Console}
  alias Beamicom.NES.Recompiler.{Equivalence, Generator, Program}

  test "emits one packed-status ABI function per block and dispatches it equivalently" do
    # LDA #$2A; TAX; JMP $8010
    prg =
      :binary.copy(<<0x02>>, 0x4000)
      |> put_bytes(0x8000, <<0xA9, 0x2A, 0xAA, 0x4C, 0x10, 0x80>>)
      |> put_bytes(0x8010, <<0xE8, 0x60>>)
      |> put_vector(0xFFFA, 0x8010)
      |> put_vector(0xFFFC, 0x8000)
      |> put_vector(0xFFFE, 0x8010)

    cart = %Cart{mapper: 0, prg_rom: prg}
    assert {:ok, program} = Generator.compile(cart)

    assert program.module == Generator.module_name(:crypto.hash(:sha256, prg))
    assert program.module.block_starts() == [0x8000, 0x8010]
    assert function_exported?(program.module, :block_8000, 8)
    assert function_exported?(program.module, :block_8010, 8)

    start = console(prg, 0x8000)
    candidate = fn state -> Program.step(program, state) end

    assert {:ok, result} = Equivalence.compare(start, candidate)
    assert result.cpu.pc == 0x8010
    assert result.cpu.a == 0x2A
    assert result.cpu.x == 0x2A
    assert result.cpu.p == 0x24

    assert Program.statistics(program) == %{
             compiled_blocks: 1,
             compiled_instructions: 3,
             fallback_transitions: 0,
             fallback_instructions: 0
           }
  end

  test "unknown and RAM targets execute exactly one interpreter fallback step" do
    prg =
      :binary.copy(<<0x02>>, 0x4000)
      |> put_bytes(0x8000, <<0xEA, 0x60>>)
      |> put_vector(0xFFFA, 0x8000)
      |> put_vector(0xFFFC, 0x8000)
      |> put_vector(0xFFFE, 0x8000)

    assert {:ok, program} = Generator.compile(%Cart{mapper: 0, prg_rom: prg})
    start = console(prg, 0x0010)

    assert {:ok, result} =
             Equivalence.compare(start, fn state -> Program.step(program, state) end)

    # Zero-filled RAM contains BRK, so the interpreter fallback vectors to IRQ.
    assert result.cpu.pc == 0x8000

    assert Program.statistics(program) == %{
             compiled_blocks: 0,
             compiled_instructions: 0,
             fallback_transitions: 1,
             fallback_instructions: 1
           }
  end

  test "interrupt redirection stops a block before its next static instruction" do
    prg =
      :binary.copy(<<0x02>>, 0x4000)
      |> put_bytes(0x8000, <<0xEA, 0xEA, 0x60>>)
      |> put_bytes(0x8100, <<0x40>>)
      |> put_vector(0xFFFA, 0x8100)
      |> put_vector(0xFFFC, 0x8000)
      |> put_vector(0xFFFE, 0x8100)

    assert {:ok, program} = Generator.compile(%Cart{mapper: 0, prg_rom: prg})
    start = console(prg, 0x8000)
    start = %{start | cpu: %{start.cpu | nmi_pending: true}}

    assert {:ok, result} =
             Equivalence.compare(start, fn state -> Program.step(program, state) end)

    assert result.cpu.pc == 0x8100
    assert Program.statistics(program).compiled_instructions == 1
  end

  @tag timeout: 30_000
  test "generated block transitions match the interpreter on mapper-0 nestest" do
    media = File.read!("test/support/fixtures/nestest.nes")
    start = Console.load_binary(media)
    assert {:ok, program} = Generator.compile_media(media)

    assert {:ok, _result} =
             Equivalence.compare_many(start, fn state -> Program.step(program, state) end, 500)

    stats = Program.statistics(program)
    assert stats.compiled_blocks > 0
    assert stats.compiled_instructions >= stats.compiled_blocks
  end

  defp console(prg, pc) do
    bus = %Bus{
      ram: <<0::size(0x800 * 8)>>,
      wram: %{},
      prg: prg,
      prg_banks: {0, 0x2000, 0, 0x2000},
      mapper: 0
    }

    %Console{cpu: %CPU{pc: pc, cycles: 7}, bus: bus}
  end

  defp put_vector(prg, address, target),
    do: put_bytes(prg, address, <<target &&& 0xFF, target >>> 8>>)

  defp put_bytes(prg, address, bytes) do
    offset = rem(address - 0x8000, byte_size(prg))
    suffix_offset = offset + byte_size(bytes)

    binary_part(prg, 0, offset) <>
      bytes <>
      binary_part(prg, suffix_offset, byte_size(prg) - suffix_offset)
  end
end
