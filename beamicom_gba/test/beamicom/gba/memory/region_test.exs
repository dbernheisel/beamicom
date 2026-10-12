defmodule Beamicom.GBA.Memory.RegionTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.Memory.Region

  test "reads, writes, wraps, and snapshots page-chunked memory" do
    region = Region.new(1024, page_size: 256)
    region = region |> Region.write(0, 0x12) |> Region.write(511, 0x34)
    wrapped = Region.write(region, 1024, 0x56)

    assert Region.read(region, 0) == 0x12
    assert Region.read(region, 511) == 0x34
    assert Region.read(region, 1024) == 0x12
    assert Region.read(wrapped, 0) == 0x56
    assert Region.read(region, 0) == 0x12

    binary = Region.to_binary(wrapped)
    assert byte_size(binary) == 1024
    assert Region.from_binary(binary, page_size: 256) == wrapped
  end

  test "requires exact positive page geometry" do
    assert_raise ArgumentError, fn -> Region.new(10, page_size: 4) end
    assert_raise ArgumentError, fn -> Region.from_binary(<<1, 2, 3>>, page_size: 2) end
  end

  test "reads and writes packed binaries across pages and wrapped boundaries" do
    original = Region.new(16, page_size: 4)
    region = Region.write_binary(original, 14, <<1, 2, 3, 4, 5, 6>>)

    assert Region.read_binary(region, 14, 6) == <<1, 2, 3, 4, 5, 6>>
    assert Region.read_binary(region, -2, 6) == <<1, 2, 3, 4, 5, 6>>
    assert Region.read_binary(original, 14, 6) == <<0, 0, 0, 0, 0, 0>>
    assert Region.to_binary(region) == <<3, 4, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2>>
  end

  test "reads little-endian values within and across page boundaries" do
    region =
      Region.new(16, page_size: 4)
      |> Region.write_binary(0, <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88>>)

    assert Region.read16(region, 1) == 0x3322
    assert Region.read16(region, 3) == 0x5544
    assert Region.read32(region, 0) == 0x4433_2211
    assert Region.read32(region, 2) == 0x6655_4433
    assert Region.read32(region, 14) == 0x2211_0000
  end

  test "writes little-endian values across page and wrapped boundaries" do
    region = Region.new(16, page_size: 4)
    region = Region.write16(region, 3, 0x2211)
    region = Region.write32(region, 14, 0x6655_4433)

    assert Region.read_binary(region, 0, 6) == <<0x55, 0x66, 0, 0x11, 0x22, 0>>
    assert Region.read_binary(region, 13, 3) == <<0, 0x33, 0x44>>
  end
end
