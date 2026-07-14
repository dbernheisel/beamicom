defmodule Beamicom.NES.ControllersTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Bus, Cart, Controllers, PPU}

  @moduledoc "Standard controller shift-register readout (spec §5.4)."

  defp bus do
    cart = %Cart{mapper: 0, prg_rom: <<0>>, chr_rom: <<>>, mirroring: :horizontal, battery: false}
    Bus.new(cart, PPU.new(<<>>, :horizontal))
  end

  # Latch (strobe 1 then 0) and read the port eight+ times.
  defp read_seq(bus, addr, n) do
    bus = bus |> Bus.write(0x4016, 1) |> Bus.write(0x4016, 0)

    {bits, _bus} =
      Enum.map_reduce(1..n, bus, fn _, b ->
        {bit, b} = Bus.read(b, addr)
        {bit, b}
      end)

    bits
  end

  test "reads A,B,Select,Start,Up,Down,Left,Right in order, then 1s" do
    # A + Start + Right pressed.
    bus = Bus.set_buttons(bus(), 1, Controllers.mask([:a, :start, :right]))
    # A B Se St Up Dn Lf Rt  then two extra reads.
    assert read_seq(bus, 0x4016, 10) == [1, 0, 0, 1, 0, 0, 0, 1, 1, 1]
  end

  test "port 2 is independent" do
    bus = Bus.set_buttons(bus(), 2, Controllers.mask([:b, :down]))
    assert read_seq(bus, 0x4017, 8) == [0, 1, 0, 0, 0, 1, 0, 0]
  end

  test "while strobing, reads keep returning button A" do
    bus = bus() |> Bus.set_buttons(1, Controllers.mask([:a])) |> Bus.write(0x4016, 1)
    {b1, bus} = Bus.read(bus, 0x4016)
    {b2, _bus} = Bus.read(bus, 0x4016)
    assert {b1, b2} == {1, 1}
  end
end
