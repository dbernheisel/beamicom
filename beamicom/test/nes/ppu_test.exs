defmodule Beamicom.NES.PPUTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.NES.PPU

  # 8KB CHR filled so pattern-table reads are distinguishable, horizontal mirroring.
  defp ppu, do: PPU.new(:binary.copy(<<0x5A>>, 0x2000), :horizontal)

  # Set the VRAM address via two $2006 writes (high byte first).
  defp set_addr(ppu, addr),
    do:
      ppu
      |> PPU.write_register(0x2006, addr >>> 8)
      |> PPU.write_register(0x2006, addr &&& 0xFF)

  test "$2007 writes to nametable VRAM and reads back through the buffer" do
    ppu = ppu() |> set_addr(0x2000) |> PPU.write_register(0x2007, 0xAB)

    # Reading is delayed one step: first read returns stale buffer, second the data.
    ppu = set_addr(ppu, 0x2000)
    {_stale, ppu} = PPU.read_register(ppu, 0x2007)
    {value, _ppu} = PPU.read_register(ppu, 0x2007)
    assert value == 0xAB
  end

  test "VRAM address increments by 1, or 32 when PPUCTRL bit 2 is set" do
    ppu =
      ppu() |> set_addr(0x2000) |> PPU.write_register(0x2007, 1) |> PPU.write_register(0x2007, 2)

    ppu = set_addr(ppu, 0x2001)
    {_, ppu} = PPU.read_register(ppu, 0x2007)
    {second, _} = PPU.read_register(ppu, 0x2007)
    assert second == 2

    ppu =
      ppu()
      |> PPU.write_register(0x2000, 0x04)
      |> set_addr(0x2000)
      |> PPU.write_register(0x2007, 0x11)
      |> PPU.write_register(0x2007, 0x22)

    ppu = set_addr(ppu, 0x2020)
    {_, ppu} = PPU.read_register(ppu, 0x2007)
    {v, _} = PPU.read_register(ppu, 0x2007)
    assert v == 0x22
  end

  test "palette reads are immediate (not buffered)" do
    ppu = ppu() |> set_addr(0x3F00) |> PPU.write_register(0x2007, 0x2A)
    ppu = set_addr(ppu, 0x3F00)
    {value, _} = PPU.read_register(ppu, 0x2007)
    assert value == 0x2A
  end

  test "palette $3F10/$14/$18/$1C mirror down to $3F00/$04/$08/$0C" do
    ppu = ppu() |> set_addr(0x3F00) |> PPU.write_register(0x2007, 0x0C)
    ppu = set_addr(ppu, 0x3F10)
    {value, _} = PPU.read_register(ppu, 0x2007)
    assert value == 0x0C
  end

  test "$2002 read clears the vblank flag and resets the write latch" do
    ppu = %{ppu() | status: 0x80}
    {value, ppu} = PPU.read_register(ppu, 0x2002)
    assert (value &&& 0x80) == 0x80
    assert (ppu.status &&& 0x80) == 0
    assert ppu.w == 0
  end

  test "OAM: $2004 write increments the address, read does not; attribute byte masks $E3" do
    ppu =
      ppu()
      |> PPU.write_register(0x2003, 0)
      |> PPU.write_register(0x2004, 0x11)
      |> PPU.write_register(0x2004, 0x22)
      |> PPU.write_register(0x2004, 0xFF)

    assert ppu.oam_addr == 3

    ppu = PPU.write_register(ppu, 0x2003, 2)
    {attr, ppu} = PPU.read_register(ppu, 0x2004)
    assert attr == (0xFF &&& 0xE3)
    assert ppu.oam_addr == 2
  end
end
