defmodule Beamicom.GB.Cartridge.RAMTest do
  use ExUnit.Case, async: true

  alias Beamicom.GB.Cartridge.RAM

  test "a 128 KiB write replaces one 256-byte page and shares every other page" do
    ram = RAM.new(:binary.copy(<<0>>, 128 * 1024))
    changed_page = 341
    offset = changed_page * 256 + 173

    assert {:changed, changed} = RAM.put(ram, offset, 0xA5)
    assert tuple_size(ram.pages) == 512
    assert tuple_size(changed.pages) == 512
    assert RAM.read(changed, offset) == 0xA5
    assert RAM.read(ram, offset) == 0

    for page <- 0..511 do
      if page == changed_page do
        refute :erts_debug.same(elem(ram.pages, page), elem(changed.pages, page))
      else
        assert :erts_debug.same(elem(ram.pages, page), elem(changed.pages, page))
      end
    end

    assert byte_size(elem(changed.pages, changed_page)) == 256
  end

  test "same-value writes return the unchanged marker" do
    ram = RAM.new(:binary.copy(<<0x5A>>, 512))

    assert :unchanged = RAM.put(ram, 300, 0x5A)
  end

  test "flat persistence conversion exactly round-trips page boundaries" do
    source = :binary.list_to_bin(for value <- 0..511, do: rem(value, 256))
    ram = RAM.new(source)

    assert RAM.read(ram, 255) == 255
    assert RAM.read(ram, 256) == 0
    assert RAM.to_binary(ram) == source
  end
end
