defmodule Beamicom.SNES.APUTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, DSP, DSPTask, SPC700}

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

  test "native IPL publishes its hardware ready signature" do
    apu = APU.new(native_ipl: true) |> APU.advance(60_000, :ntsc)

    assert APU.cpu_read(apu, 0) == 0xAA
    assert APU.cpu_read(apu, 1) == 0xBB
    assert apu.spc.pc in 0xFFCF..0xFFD2
    assert apu.spc.error == nil
  end

  test "native IPL uploads and launches a program through the CPU ports" do
    apu =
      APU.new(native_ipl: true)
      |> advance_until_port(0, 0xAA)
      |> advance_until_port(1, 0xBB)

    apu =
      apu
      |> APU.cpu_write(2, 0x00)
      |> APU.cpu_write(3, 0x02)
      |> APU.cpu_write(1, 0x01)
      |> APU.cpu_write(0, 0xCC)
      |> advance_until_port(0, 0xCC)

    # MOV $F4,#$42; BRA -2. The uploaded program makes its launch observable
    # without relying on DSP state.
    apu =
      [0x8F, 0x42, 0xF4, 0x2F, 0xFE]
      |> Enum.with_index()
      |> Enum.reduce(apu, fn {byte, index}, apu ->
        apu
        |> APU.cpu_write(1, byte)
        |> APU.cpu_write(0, index)
        |> advance_until_port(0, index)
      end)

    apu =
      apu
      |> APU.cpu_write(2, 0x00)
      |> APU.cpu_write(3, 0x02)
      |> APU.cpu_write(1, 0x00)
      |> APU.cpu_write(0, 0x06)
      |> advance_until_port(0, 0x42)

    assert apu.spc.pc in [0x0203, 0x0205]
    assert apu.spc.error == nil
    assert :array.get(0x0200, apu.spc.ram) == 0x8F
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

  test "async DSP synthesis publishes the preceding completed batch" do
    clocks = 357_368

    sync = APU.new(native_ipl: true) |> APU.advance(clocks, :ntsc)
    {expected_frames, expected_pcm, _sync} = APU.take_pcm(sync)

    async = APU.new(native_ipl: true, async_dsp: true) |> APU.advance(clocks, :ntsc)
    assert {0, <<>>, async} = APU.take_pcm(async)
    assert %DSPTask{} = async.dsp_task

    # Completed DSP work stays in its worker until the next APU boundary. It
    # must not leak a Task reply into a host GenServer's handle_info mailbox.
    refute_receive {_reference, _result}, 100

    async = APU.advance(async, clocks, :ntsc)
    assert {^expected_frames, ^expected_pcm, async} = APU.take_pcm(async)

    {tail_frames, tail_pcm, async} = APU.drain_pcm(async)
    assert tail_frames > 0
    assert byte_size(tail_pcm) == tail_frames * 4
    assert async.dsp_task == nil
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "async APU batches accept the Nx DSP renderer without changing output" do
      clocks = 357_368

      native = APU.new(native_ipl: true) |> APU.advance(clocks, :ntsc)
      {expected_frames, expected_pcm, _native} = APU.take_pcm(native)

      nx =
        APU.new(
          native_ipl: true,
          async_dsp: true,
          apu_renderer: Beamicom.SNES.Nx.DSPRenderer
        )
        |> APU.advance(clocks, :ntsc)
        |> APU.advance(clocks, :ntsc)

      assert nx.apu_renderer == Beamicom.SNES.Nx.DSPRenderer
      assert {^expected_frames, ^expected_pcm, _nx} = APU.take_pcm(nx)
    end
  end

  test "SPC instruction overruns become debt across fragmented cycle grants" do
    ram = :array.new(0x10000, default: 0, fixed: true)
    initial = SPC700.new(ram, 0)
    overdrawn = SPC700.run(initial, 1)
    settled = SPC700.run(overdrawn, 1)

    assert {overdrawn.pc, overdrawn.cycles, overdrawn.cycle_credit} == {1, 2, -1}
    assert {settled.pc, settled.cycles, settled.cycle_credit} == {1, 2, 0}

    batched = SPC700.run(initial, 100)

    fragmented =
      Enum.reduce(1..100, initial, fn _, spc ->
        SPC700.run(spc, 1)
      end)

    assert fragmented.pc == batched.pc
    assert fragmented.cycles == batched.cycles
    assert fragmented.cycle_credit == batched.cycle_credit
    assert {fragmented.pc, fragmented.cycles, fragmented.cycle_credit} == {50, 100, 0}
  end

  test "APU clock fragmentation does not overclock its running SPC" do
    ram = :array.new(0x10000, default: 0, fixed: true)
    spc = SPC700.new(ram, 0)
    initial = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    batched = APU.advance(initial, 2_000, :pal)

    fragmented =
      Enum.reduce(1..2_000, initial, fn _, apu ->
        APU.advance(apu, 1, :pal)
      end)

    assert fragmented.spc.pc == batched.spc.pc
    assert fragmented.spc.cycles == batched.spc.cycles
    assert fragmented.spc.cycle_credit == batched.spc.cycle_credit
    assert fragmented.spc_phase == batched.spc_phase
    assert fragmented.pending_spc_cycles == batched.pending_spc_cycles
  end

  test "SPC timestamps DSP writes at the memory-access cycle" do
    ram = spc_ram([{0, 0x8F}, {1, 0x4C}, {2, 0xF2}, {3, 0x8F}, {4, 0x01}, {5, 0xF3}])
    spc = SPC700.new(ram, 0) |> SPC700.run(10)

    assert spc.dsp_events == [{10, 0x4C, 0x01}]
    assert spc.bus_cycle == 0
    assert spc.bus_counter == nil
    assert spc.cycles == 10
  end

  test "SPC dummy reads preserve timer output register side effects" do
    ram = spc_ram([{0xFC, 0x00}])

    spc =
      %{SPC700.new(ram, 0xFC) | timer_outputs: {5, 0, 0}}
      |> SPC700.run(1)

    assert spc.pc == 0xFD
    assert spc.timer_outputs == {0, 0, 0}
  end

  test "SPC timer divider phase free-runs while disabled and survives enable" do
    ram = spc_ram([{0, 0x8F}, {1, 0x01}, {2, 0xF1}])

    spc =
      %{SPC700.new(ram, 0) | cycles: 127}
      |> SPC700.run(5)

    assert spc.control == 0x01
    assert spc.timer_phase == {4, 4, 4}
    assert spc.timer_stages == {0, 0, 0}
    assert spc.timer_outputs == {0, 0, 0}
    assert spc.timer_last_cycles == {132, 132, 132}
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

  test "SPC timer target changes wait for exact equality after an 8-bit wrap" do
    instructions =
      [{0, 0x8F}, {1, 0x01}, {2, 0xFA}] ++
        Enum.map(0..60, &{3 + &1, 0x00}) ++ [{64, 0xE4}, {65, 0xFD}]

    spc = %{
      SPC700.new(spc_ram(instructions), 0)
      | control: 0x01,
        timer_targets: {3, 0, 0},
        timer_stages: {2, 0, 0}
    }

    spc = SPC700.run(spc, 130)

    assert spc.a == 0
    assert spc.timer_targets == {1, 0, 0}
    assert spc.timer_stages == {3, 0, 0}
    assert spc.timer_phase == {2, 0, 0}
    assert spc.timer_outputs == {0, 0, 0}
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

  defp advance_until_port(apu, port, expected, attempts \\ 2_000)

  defp advance_until_port(apu, port, expected, 0) do
    flunk(
      "APU port #{port} did not become #{expected}: " <>
        inspect(%{
          pc: apu.spc.pc,
          input: apu.spc.input_ports,
          output: apu.spc.output_ports,
          x: apu.spc.x,
          y: apu.spc.y,
          error: apu.spc.error
        })
    )
  end

  defp advance_until_port(apu, port, expected, attempts) do
    if APU.cpu_read(apu, port) == expected do
      apu
    else
      apu
      |> APU.advance(128, :ntsc)
      |> advance_until_port(port, expected, attempts - 1)
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

  test "SPC ignores DSPDATA writes when DSPADDR bit 7 is set" do
    ram =
      spc_ram([
        {0, 0x8F},
        {1, 0xDC},
        {2, 0xF2},
        {3, 0x8F},
        {4, 0xFF},
        {5, 0xF3}
      ])

    spc = SPC700.new(ram, 0) |> SPC700.run(10)
    assert spc.dsp_addr == 0xDC
    assert DSP.read(spc.dsp, 0x5C) == 0
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
    assert DSP.read(looping, 0x7C) == 1

    {restarted, _pcm} = looping |> DSP.write(0x4C, 0x01) |> DSP.render(ram, 1)
    assert DSP.read(restarted, 0x7C) == 0
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "Nx DSP block mixing is bit-identical to the native mixer" do
      ram =
        Enum.reduce(
          [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, 0x13}],
          :array.new(0x10000, default: 0, fixed: true),
          fn {address, value}, ram -> :array.set(address, value, ram) end
        )

      ram =
        Enum.reduce(0x201..0x208, ram, fn address, ram ->
          :array.set(address, 0x71 + rem(address, 7), ram)
        end)

      dsp =
        Enum.reduce(0..7, DSP.new(), fn index, dsp ->
          base = index * 0x10

          dsp
          |> DSP.write(base, 0x70 - index * 9)
          |> DSP.write(base + 1, 0x90 + index * 7)
          |> DSP.write(base + 2, index * 0x21)
          |> DSP.write(base + 3, 0x10)
          |> DSP.write(base + 4, 0)
        end)
        |> DSP.write(0x0C, 0x71)
        |> DSP.write(0x1C, 0x9B)
        |> DSP.write(0x5D, 0x01)
        |> DSP.write(0x4C, 0xFF)

      {native, native_pcm} = DSP.render(dsp, ram, 256)

      {nx, nx_pcm} =
        DSP.render(dsp, ram, 256, Beamicom.SNES.Nx.DSPRenderer)

      assert nx == native
      assert nx_pcm == native_pcm
      refute nx_pcm == :binary.copy(<<0>>, byte_size(nx_pcm))

      {native_long, native_long_pcm} = DSP.render(native, ram, 4096)

      {nx_long, nx_long_pcm} =
        DSP.render(nx, ram, 4096, Beamicom.SNES.Nx.DSPRenderer)

      assert nx_long == native_long
      assert nx_long_pcm == native_long_pcm
    end
  end

  test "DSP keeps KOFF asserted and replaces pending KON writes" do
    ram =
      Enum.reduce(
        [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, 0x13}],
        :array.new(0x10000, default: 0, fixed: true),
        fn {address, value}, ram -> :array.set(address, value, ram) end
      )

    dsp =
      DSP.new()
      |> DSP.write(0x02, 0x00)
      |> DSP.write(0x03, 0x10)
      |> DSP.write(0x04, 0x00)
      |> DSP.write(0x5D, 0x01)
      |> DSP.write(0x4C, 0x01)
      |> DSP.write(0x4C, 0x00)

    {not_started, _pcm} = DSP.render(dsp, ram, 1)
    refute elem(not_started.voices, 0).active?

    {started, _pcm} = dsp |> DSP.write(0x4C, 0x01) |> DSP.render(ram, 1)
    assert elem(started.voices, 0).active?

    # If KON and KOFF are sampled together, KON wins for that boundary. KOFF
    # remains set, though, and stops the voice at the following boundary.
    {keyed_again, _pcm} =
      started
      |> DSP.write(0x5C, 0x01)
      |> DSP.write(0x4C, 0x01)
      |> DSP.render(ram, 1)

    assert elem(keyed_again.voices, 0).active?

    {stopped, _pcm} = DSP.render(keyed_again, ram, 1)
    refute elem(stopped.voices, 0).active?
    assert DSP.read(stopped, 0x5C) == 0x01
  end

  test "audio already produced is not erased by a later DSP mute" do
    ram =
      Enum.reduce(
        [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, 0x13}],
        :array.new(0x10000, default: 0, fixed: true),
        fn {address, value}, ram -> :array.set(address, value, ram) end
      )

    ram =
      Enum.reduce(0x201..0x208, ram, fn address, ram ->
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

    spc = %{SPC700.new(ram, 0) | dsp: dsp}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    # PAL needs 666 master clocks to cross one 32 kHz sample boundary.
    apu = APU.advance(apu, 666, :pal)
    apu = put_in(apu.spc.dsp, DSP.write(apu.spc.dsp, 0x6C, 0x40))
    apu = APU.advance(apu, 666, :pal)

    assert {2, <<first::binary-size(4), second::binary-size(4)>>, _apu} = APU.take_pcm(apu)
    refute first == <<0, 0, 0, 0>>
    assert second == <<0, 0, 0, 0>>
  end

  defp spc_ram(bytes) do
    Enum.reduce(bytes, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end
end
