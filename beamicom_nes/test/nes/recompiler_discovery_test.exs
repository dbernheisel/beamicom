defmodule Beamicom.NES.Recompiler.DiscoveryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.NES.Cart
  alias Beamicom.NES.Recompiler.Discovery

  test "recursively discovers vector roots, branches, jumps, and subroutines" do
    prg =
      :binary.copy(<<0x02>>, 0x4000)
      |> put_bytes(0x8000, <<0x20, 0x10, 0x80>>)
      |> put_bytes(0x8003, <<0xD0, 0x03>>)
      |> put_bytes(0x8005, <<0x4C, 0x20, 0x80>>)
      |> put_bytes(0x8008, <<0x6C, 0x00, 0x03>>)
      |> put_bytes(0x8010, <<0xA9, 0x01, 0x60>>)
      |> put_bytes(0x8020, <<0x00>>)
      |> put_bytes(0x8100, <<0x60>>)
      |> put_bytes(0x8200, <<0x40>>)
      |> put_vector(0xFFFA, 0x8100)
      |> put_vector(0xFFFC, 0x8000)
      |> put_vector(0xFFFE, 0x8200)

    assert {:ok, result} = Discovery.discover(%Cart{mapper: 0, prg_rom: prg})
    assert result.roots == %{nmi: 0x8100, reset: 0x8000, irq: 0x8200}

    assert Map.keys(result.instructions) |> Enum.sort() ==
             [0x8000, 0x8003, 0x8005, 0x8008, 0x8010, 0x8012, 0x8020, 0x8100, 0x8200]

    assert result.block_starts ==
             [0x8000, 0x8003, 0x8005, 0x8008, 0x8010, 0x8020, 0x8100, 0x8200]

    assert result.blocks[0x8010].addresses == [0x8010, 0x8012]
    assert result.blocks[0x8000].exit.terminator == :call

    assert %{dynamic_exit: :jmp_indirect} = result.instructions[0x8008]
    assert %{dynamic_exit: :rts} = result.instructions[0x8012]
    assert %{dynamic_exit: :brk} = result.instructions[0x8020]
  end

  test "mirrors a 16 KiB NROM PRG bank into both CPU windows" do
    prg = :binary.copy(<<0>>, 0x4000) |> put_bytes(0x8000, <<0xAA>>)
    cart = %Cart{mapper: 0, prg_rom: prg}

    assert Discovery.prg_offset(cart, 0x8000) == 0
    assert Discovery.prg_offset(cart, 0xC000) == 0
    assert Discovery.prg_offset(cart, 0xFFFF) == 0x3FFF
  end

  test "rejects non-NROM and invalid mapper-0 PRG sizes" do
    assert {:error, {:unsupported_mapper, 5}} =
             Discovery.discover(%Cart{mapper: 5, prg_rom: <<>>})

    assert {:error, {:invalid_nrom_prg_size, 3}} =
             Discovery.discover(%Cart{mapper: 0, prg_rom: <<1, 2, 3>>})
  end

  test "terminates on the checked-in mapper-0 nestest program" do
    {:ok, cart} = Cart.parse(File.read!("test/support/fixtures/nestest.nes"))

    assert {:ok, result} = Discovery.discover(cart)
    assert result.roots == %{reset: 0xC004, nmi: 0xC5AF, irq: 0xC5F4}
    assert map_size(result.instructions) > 300
    assert map_size(result.blocks) > 80
    assert result.instruction_bytes < byte_size(cart.prg_rom)
  end

  defp put_vector(prg, address, target),
    do: put_bytes(prg, address, <<target &&& 0xFF, target >>> 8>>)

  defp put_bytes(prg, address, bytes) do
    offset = rem(address - 0x8000, byte_size(prg))
    suffix_offset = offset + byte_size(bytes)
    prefix = binary_part(prg, 0, offset)
    suffix = binary_part(prg, suffix_offset, byte_size(prg) - suffix_offset)
    prefix <> bytes <> suffix
  end
end
