defmodule Beamicom.SNES.APUTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.APU

  test "keeps CPU-to-APU and APU-to-CPU ports directional" do
    apu = APU.new() |> APU.cpu_write(2, 0x1AB)
    assert APU.apu_read_cpu_port(apu, 2) == 0xAB
    assert APU.cpu_read(apu, 2) == 0

    apu = APU.apu_write_cpu_port(apu, 2, 0x55)
    assert APU.cpu_read(apu, 2) == 0x55
    assert APU.apu_read_cpu_port(apu, 2) == 0xAB
  end

  test "exposes the IPL ready signature and acknowledges bootstrap ports" do
    apu = APU.new()
    assert APU.cpu_read(apu, 0) == 0xAA
    assert APU.cpu_read(apu, 1) == 0xBB

    apu = apu |> APU.cpu_write(0, 0xFF) |> APU.cpu_write(1, 0xF0)
    assert APU.cpu_read(apu, 0) == 0xAA
    assert APU.cpu_read(apu, 1) == 0xBB

    apu = apu |> APU.cpu_write(1, 0x01) |> APU.cpu_write(0, 0xCC)
    assert APU.cpu_read(apu, 0) == 0xCC
    assert apu.ipl_state == :upload

    apu = APU.cpu_write(apu, 0, 7)
    assert APU.cpu_read(apu, 0) == 7
  end

  test "accumulates the independent NTSC audio timeline without per-clock stepping" do
    # 945,000 master clocks are exactly 44 ms at the NTSC 945/44 MHz clock.
    apu = APU.advance(APU.new(), 945_000, :ntsc)
    assert apu.pending_frames == 1_408
    assert apu.pending_spc_cycles == 45_056

    assert {45_056, apu} = APU.take_spc_cycles(apu)
    assert apu.pending_spc_cycles == 0

    assert {1_408, pcm, apu} = APU.take_pcm(apu)
    assert byte_size(pcm) == 1_408 * 2 * 2
    assert pcm == :binary.copy(<<0, 0, 0, 0>>, 1_408)
    assert apu.pending_frames == 0
  end

  test "sample phase is invariant to clock chunking" do
    once = APU.advance(APU.new(), 123_456, :pal)

    chunked =
      APU.new()
      |> APU.advance(12_345, :pal)
      |> APU.advance(100_000, :pal)
      |> APU.advance(11_111, :pal)

    assert chunked.pending_frames == once.pending_frames
    assert chunked.sample_phase == once.sample_phase
    assert chunked.pending_spc_cycles == once.pending_spc_cycles
    assert chunked.spc_phase == once.spc_phase
  end
end
