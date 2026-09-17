defmodule Beamicom.SNES.APURAMTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, SPC700}
  alias Beamicom.SNES.APU.RAM

  test "atomics RAM matches array RAM across fragmented SPC and DSP execution" do
    array = array_apu()
    atomics = APU.new(native_ipl: true)

    assert RAM.backend(array.ram) == :array
    assert RAM.backend(atomics.ram) == :atomics
    assert atomics.ram == atomics.spc.ram

    {array, atomics} =
      Enum.reduce([1, 31, 2_047, 65_537, 123_456], {array, atomics}, fn clocks,
                                                                        {array, atomics} ->
        {APU.advance(array, clocks, :ntsc), APU.advance(atomics, clocks, :ntsc)}
      end)

    {array_frames, array_pcm, array} = APU.drain_pcm(array)
    {atomics_frames, atomics_pcm, atomics} = APU.drain_pcm(atomics)

    assert atomics_frames == array_frames
    assert atomics_pcm == array_pcm
    assert canonical_snapshot(atomics) == canonical_snapshot(array)
  end

  test "an atomics snapshot is immutable and detached from live RAM" do
    apu = APU.new(native_ipl: true) |> APU.advance(10_000, :ntsc)
    snapshot = APU.snapshot(apu)
    previous = RAM.get(snapshot.ram, 0x0200)

    assert RAM.backend(snapshot.ram) == :atomics
    assert snapshot.ram == snapshot.spc.ram

    RAM.put(apu.ram, 0x0200, Bitwise.bxor(previous, 0xFF))

    assert RAM.get(snapshot.ram, 0x0200) == previous
    assert RAM.get(apu.ram, 0x0200) != previous
  end

  test "async DSP execution keeps atomics branches isolated" do
    clocks = 357_368

    array = array_apu(async_dsp: true)
    atomics = APU.new(native_ipl: true, async_dsp: true)

    array = array |> APU.advance(clocks, :ntsc) |> APU.advance(clocks, :ntsc)
    atomics = atomics |> APU.advance(clocks, :ntsc) |> APU.advance(clocks, :ntsc)

    {array_frames, array_pcm, array} = APU.drain_pcm(array)
    {atomics_frames, atomics_pcm, atomics} = APU.drain_pcm(atomics)

    assert atomics_frames == array_frames
    assert atomics_pcm == array_pcm
    assert canonical_snapshot(atomics) == canonical_snapshot(array)
  end

  defp array_apu(opts \\ []) do
    ram = RAM.new(:array)
    spc = %{SPC700.new(ram, 0xFFC0) | control: 0xB0}
    apu = APU.new(opts)
    %{apu | ram: ram, spc: spc, ipl_state: :running}
  end

  defp canonical_snapshot(apu) do
    snapshot = APU.snapshot(apu)
    ram = RAM.to_binary(snapshot.ram)
    spc = if snapshot.spc, do: %{snapshot.spc | ram: nil}, else: nil
    {ram, %{snapshot | ram: nil, spc: spc}}
  end
end
