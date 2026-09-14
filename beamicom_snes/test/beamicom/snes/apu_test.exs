defmodule Beamicom.SNES.APUTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, DSP, SPC700}

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
    {0xCC, apu} = APU.sync_cpu_read(apu, 0)
    assert apu.ipl_state == :upload

    apu = APU.cpu_write(apu, 0, 7)
    {7, apu} = APU.sync_cpu_read(apu, 0)
    assert apu.ipl_counter == 7
  end

  test "starts an uploaded driver after exposing the final IPL acknowledgement" do
    apu =
      APU.new()
      |> APU.cpu_write(2, 0x00)
      |> APU.cpu_write(3, 0x02)
      |> APU.cpu_write(1, 0x01)
      |> APU.cpu_write(0, 0xCC)

    {0xCC, apu} = APU.sync_cpu_read(apu, 0)

    apu = apu |> APU.cpu_write(1, 0x00) |> APU.cpu_write(0, 0x00)
    {0x00, apu} = APU.sync_cpu_read(apu, 0)

    apu = apu |> APU.cpu_write(1, 0x00) |> APU.cpu_write(0, 0x02)
    {0x02, apu} = APU.sync_cpu_read(apu, 0)

    assert apu.ipl_state == :running
    assert apu.spc.pc == 0x0200
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

  test "lazy SPC timers synchronize and clear when their output register is read" do
    ram =
      Enum.reduce(
        [{0, 0xE4}, {1, 0xFD}, {2, 0xFF}],
        :array.new(0x10000, default: 0, fixed: true),
        fn {address, value}, ram -> :array.set(address, value, ram) end
      )

    spc = %{
      SPC700.new(ram, 0)
      | control: 0x01,
        timer_targets: {1, 0, 0},
        cycles: 256
    }

    spc = SPC700.run(spc, 10)
    assert spc.a == 2
    assert elem(spc.timer_outputs, 0) == 0
    assert spc.error == nil
  end

  test "SPC fetches the enabled internal IPL ROM over underlying RAM" do
    ram = :array.new(0x10000, default: 0, fixed: true)
    spc = SPC700.new(ram, 0xFFC0) |> SPC700.run(1)
    assert spc.x == 0xEF
    assert spc.pc == 0xFFC2
  end

  test "SPC POP register instructions preserve every status flag" do
    for {opcode, register} <- [{0xAE, :a}, {0xCE, :x}, {0xEE, :y}] do
      ram = spc_ram([{0, opcode}, {0x01FF, 0x00}])
      spc = %{SPC700.new(ram, 0) | sp: 0xFE, psw: 0xFF} |> SPC700.run(1)

      assert Map.fetch!(spc, register) == 0
      assert spc.psw == 0xFF
      assert spc.sp == 0xFF
      assert spc.cycles == 4
    end
  end

  test "SPC DIV reproduces the overflow path and flags" do
    spc =
      %{SPC700.new(spc_ram([{0, 0x9E}]), 0) | a: 225, x: 83, y: 128, psw: 97}
      |> SPC700.run(1)

    assert {spc.a, spc.x, spc.y} == {141, 83, 42}
    assert spc.psw == 225
    assert spc.cycles == 12
  end

  test "SPC BRK stacks the return state and loads its vector" do
    ram = spc_ram([{0x1234, 0x0F}, {0xFFDE, 0x78}, {0xFFDF, 0x56}])
    spc = %{SPC700.new(ram, 0x1234) | control: 0, sp: 0xEF, psw: 0xA5} |> SPC700.run(1)

    assert spc.pc == 0x5678
    assert spc.sp == 0xEC
    assert spc.psw == 0xB1
    assert :array.get(0x01EF, spc.ram) == 0x12
    assert :array.get(0x01EE, spc.ram) == 0x35
    assert :array.get(0x01ED, spc.ram) == 0xA5
    assert spc.cycles == 8
  end

  test "SPC SLEEP and STOP consume their hardware bus sequence" do
    for opcode <- [0xEF, 0xFF] do
      spc = SPC700.new(spc_ram([{0, opcode}]), 0) |> SPC700.run(1)
      assert spc.stopped?
      assert spc.pc == 1
      assert spc.cycles == 7
    end
  end

  test "DSP decodes BRR into PCM and honors the end and loop flags" do
    base_ram =
      Enum.reduce(
        [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}],
        :array.new(0x10000, default: 0, fixed: true),
        fn {address, value}, ram -> :array.set(address, value, ram) end
      )

    configure = fn header ->
      ram =
        Enum.reduce(0x201..0x208, :array.set(0x200, header, base_ram), fn address, ram ->
          :array.set(address, 0x77, ram)
        end)

      dsp =
        DSP.new()
        |> DSP.write(0x00, 0x7F)
        |> DSP.write(0x01, 0x7F)
        |> DSP.write(0x02, 0x00)
        |> DSP.write(0x03, 0x10)
        |> DSP.write(0x04, 0x00)
        |> DSP.write(0x0C, 0x7F)
        |> DSP.write(0x1C, 0x7F)
        |> DSP.write(0x5D, 0x01)
        |> DSP.write(0x4C, 0x01)

      {dsp, ram}
    end

    {ended, ram} = configure.(0x11)
    {ended, pcm} = DSP.render(ended, ram, 20)
    refute pcm == :binary.copy(<<0>>, byte_size(pcm))
    refute elem(ended.voices, 0).active?
    assert DSP.read(ended, 0x7C) == 1

    {looping, ram} = configure.(0x13)
    {looping, _pcm} = DSP.render(looping, ram, 20)
    assert elem(looping.voices, 0).active?
  end

  defp spc_ram(bytes) do
    Enum.reduce(bytes, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end
end
