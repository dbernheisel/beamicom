defmodule Beamicom.SNES.APUDMATimelineTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, Bus, Cartridge, DSP, SPC700}
  alias Beamicom.SNESTestROM

  test "DMA advances the APU between sequential CPU-port writes" do
    {:ok, cartridge} = :lorom |> SNESTestROM.build() |> Cartridge.load()
    bus = Bus.new(cartridge, region: :pal)
    ram = :array.new(0x10000, default: 0, fixed: true)
    spc = SPC700.new(ram, 0)
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}
    bus = %{bus | apu: apu}

    bus =
      [0x11, 0x22, 0x33, 0x44]
      |> Enum.with_index()
      |> Enum.reduce(bus, fn {value, offset}, bus ->
        {bus, 8} = Bus.write(bus, 0x7E0000 + offset, value)
        bus
      end)

    bus =
      bus
      |> write(0x4300, 0x04)
      |> write(0x4301, 0x40)
      |> write(0x4302, 0)
      |> write(0x4303, 0)
      |> write(0x4304, 0x7E)
      |> write(0x4305, 4)
      |> write(0x4306, 0)

    before = bus.timing.master_clocks
    {bus, 6} = Bus.write(bus, 0x420B, 1)

    assert bus.timing.master_clocks - before == 46
    assert bus.apu.cpu_to_apu == {0x11, 0x22, 0x33, 0x44}
    assert DSP.phase(bus.apu.spc.dsp) > 0
    assert bus.apu.elapsed_master_clocks > 0
  end

  defp write(bus, address, value) do
    {bus, _clocks} = Bus.write(bus, address, value)
    bus
  end
end
