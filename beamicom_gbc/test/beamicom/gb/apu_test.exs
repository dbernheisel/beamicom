defmodule Beamicom.GB.APUTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.{APU, Bus, Machine}

  @clock_rate 4_194_304

  test "register masks, unused space, and power-off clearing follow NR semantics" do
    apu =
      APU.new()
      |> APU.write(0xFF30, 0xA5)
      |> power_on()
      |> APU.write(0xFF10, 0x7F)
      |> APU.write(0xFF11, 0xC0)
      |> APU.write(0xFF12, 0xF3)
      |> APU.write(0xFF13, 0x12)
      |> APU.write(0xFF14, 0x87)

    assert APU.read(apu, 0xFF10) == 0xFF
    assert APU.read(apu, 0xFF11) == 0xFF
    assert APU.read(apu, 0xFF12) == 0xF3
    assert APU.read(apu, 0xFF13) == 0xFF
    assert APU.read(apu, 0xFF14) == 0xBF
    assert APU.read(apu, 0xFF27) == 0xFF
    assert APU.read(apu, 0xFF2F) == 0xFF
    assert (APU.read(apu, 0xFF26) &&& 0x81) == 0x81

    off = APU.write(apu, 0xFF26, 0)
    assert APU.read(off, 0xFF26) == 0x70
    assert APU.read(off, 0xFF12) == 0
    assert APU.read(off, 0xFF30) == 0xA5
    assert APU.write(off, 0xFF12, 0xF0) == off
  end

  test "DAC disable immediately silences a pulse and blocks its trigger" do
    apu =
      powered()
      |> APU.write(0xFF17, 0xF0)
      |> APU.write(0xFF19, 0x80)

    assert apu.ch2.enabled
    assert (APU.read(apu, 0xFF26) &&& 0x02) != 0

    apu = apu |> APU.write(0xFF17, 0) |> APU.write(0xFF19, 0x80)
    refute apu.ch2.dac
    refute apu.ch2.enabled
    assert (APU.read(apu, 0xFF26) &&& 0x02) == 0
  end

  test "pulse trigger loads frequency, duty timer, and initial envelope volume" do
    apu =
      powered()
      |> APU.write(0xFF16, 0x80)
      |> APU.write(0xFF17, 0xA2)
      |> APU.write(0xFF18, 0xFF)
      |> APU.write(0xFF19, 0x87)

    assert %{enabled: true, duty: 2, frequency: 0x7FF, timer: 4, volume: 10} = apu.ch2
    assert APU.tick(apu, 3).ch2.duty_pos == 0
    assert APU.tick(apu, 4).ch2.duty_pos == 1
  end

  test "length, envelope, and CH1 sweep are clocked by frame-sequencer steps" do
    length =
      powered()
      |> APU.write(0xFF16, 0x3F)
      |> APU.write(0xFF17, 0xF0)
      |> APU.write(0xFF19, 0xC0)
      |> Map.put(:sequencer_step, 0)
      |> APU.clock_frame_sequencer()

    refute length.ch2.enabled

    envelope =
      powered()
      |> APU.write(0xFF17, 0x19)
      |> APU.write(0xFF19, 0x80)
      |> Map.put(:sequencer_step, 7)
      |> APU.clock_frame_sequencer()

    assert envelope.ch2.volume == 2

    swept =
      powered()
      |> APU.write(0xFF10, 0x11)
      |> APU.write(0xFF12, 0xF0)
      |> APU.write(0xFF13, 0x00)
      |> APU.write(0xFF14, 0xC2)
      |> Map.put(:sequencer_step, 2)
      |> APU.clock_frame_sequencer()

    assert swept.ch1.frequency == 0x300
    assert swept.ch1.length_enable
    assert (APU.read(swept, 0xFF14) &&& 0x40) != 0

    overflowed =
      powered()
      |> APU.write(0xFF10, 0x11)
      |> APU.write(0xFF12, 0xF0)
      |> APU.write(0xFF13, 0x00)
      |> APU.write(0xFF14, 0x86)

    refute overflowed.ch1.enabled
  end

  test "expired zero-period sweep reloads eight without changing frequency registers" do
    apu = sweep_ready(0, 1, 0x200)
    registers = sweep_registers(apu)

    swept = APU.clock_frame_sequencer(apu)

    assert swept.ch1.sweep_timer == 8
    assert {swept.ch1.frequency, swept.ch1.sweep_shadow} == {0x200, 0x200}
    assert sweep_registers(swept) == registers
  end

  test "expired zero-shift sweep leaves frequency registers unchanged" do
    apu = sweep_ready(1, 0, 0x200)
    registers = sweep_registers(apu)

    swept = APU.clock_frame_sequencer(apu)

    assert swept.ch1.enabled
    assert {swept.ch1.frequency, swept.ch1.sweep_shadow} == {0x200, 0x200}
    assert sweep_registers(swept) == registers
  end

  test "first sweep calculation overflow disables without committing frequency" do
    apu = sweep_ready(1, 1, 0x600)
    registers = sweep_registers(apu)

    swept = APU.clock_frame_sequencer(apu)

    refute swept.ch1.enabled
    assert {swept.ch1.frequency, swept.ch1.sweep_shadow} == {0x600, 0x600}
    assert sweep_registers(swept) == registers
  end

  test "second sweep calculation overflow commits once and then disables" do
    apu = sweep_ready(1, 1, 0x400)

    swept = APU.clock_frame_sequencer(apu)

    refute swept.ch1.enabled
    assert {swept.ch1.frequency, swept.ch1.sweep_shadow} == {0x600, 0x600}
    assert sweep_registers(swept) == {0x00, 0x06}
  end

  test "successful sweep writeback preserves the NR14 length-enable bit" do
    apu = sweep_ready(1, 1, 0x200)
    apu = %{apu | registers: put_elem(apu.registers, 4, 0x42)}

    swept = APU.clock_frame_sequencer(apu)

    assert swept.ch1.enabled
    assert {swept.ch1.frequency, swept.ch1.sweep_shadow} == {0x300, 0x300}
    assert sweep_registers(swept) == {0x00, 0x43}
  end

  test "length clocks inactive channels and NRx4 applies phase-sensitive extra clocks" do
    inactive =
      powered()
      |> APU.write(0xFF16, 0x3E)
      |> APU.write(0xFF17, 0)
      |> APU.write(0xFF19, 0x40)

    refute inactive.ch2.enabled
    assert inactive.ch2.length == 2
    assert APU.clock_frame_sequencer(inactive).ch2.length == 1

    even_phase = powered() |> APU.write(0xFF16, 0x3F)
    assert APU.write(even_phase, 0xFF19, 0x40).ch2.length == 1

    odd_phase = even_phase |> Map.put(:sequencer_phase, 8_191) |> APU.tick(1)
    assert odd_phase.sequencer_step == 1
    assert APU.write(odd_phase, 0xFF19, 0x40).ch2.length == 0

    even_reload =
      powered()
      |> APU.write(0xFF17, 0xF0)
      |> APU.write(0xFF19, 0xC0)

    odd_reload =
      powered()
      |> APU.write(0xFF17, 0xF0)
      |> Map.put(:sequencer_step, 1)
      |> APU.write(0xFF19, 0xC0)

    assert even_reload.ch2.length == 64
    assert odd_reload.ch2.length == 63
    assert odd_reload.ch2.enabled
  end

  test "NR52 power-off preserves and continues the DIV-APU sequencer" do
    apu = %{powered() | sequencer_step: 6, sequencer_phase: 8_000}
    off = APU.write(apu, 0xFF26, 0)

    refute off.master
    assert {off.sequencer_step, off.sequencer_phase} == {6, 8_000}

    advanced = APU.tick(off, 192)
    assert {advanced.sequencer_step, advanced.sequencer_phase} == {7, 0}
    assert APU.clock_frame_sequencer(advanced).sequencer_step == 0
  end

  test "wave trigger retains its sample buffer and first fetch selects nibble 1" do
    base =
      APU.new()
      |> APU.write(0xFF30, 0x1F)
      |> power_on()
      |> APU.write(0xFF1A, 0x80)
      |> APU.write(0xFF1C, 0x20)
      |> APU.write(0xFF1D, 0)
      |> APU.write(0xFF1E, 0x80)
      |> APU.write(0xFF24, 0)
      |> APU.write(0xFF25, 0x04)

    assert APU.read(base, 0xFF30) == 0x1F
    assert {base.ch3.position, base.ch3.sample_buffer} == {0, 0}
    assert {APU.tick(base, 4_095).ch3.position, APU.tick(base, 4_095).ch3.sample_buffer} == {0, 0}

    fetched = APU.tick(base, 4_096)
    assert {fetched.ch3.position, fetched.ch3.sample_buffer} == {1, 15}

    retriggered = APU.write(fetched, 0xFF1E, 0x80)
    assert {retriggered.ch3.position, retriggered.ch3.sample_buffer} == {0, 15}

    {_, _, fetched} = APU.take_samples(fetched)

    {1, <<0::little-signed-16, full::little-signed-16>>, _apu} =
      fetched |> APU.tick(89) |> APU.take_samples()

    half = APU.write(fetched, 0xFF1C, 0x40)

    {1, <<0::little-signed-16, shifted::little-signed-16>>, _apu} =
      half |> APU.tick(89) |> APU.take_samples()

    assert full < 0
    assert shifted - full == 1_024
  end

  test "noise uses the documented divisor and mirrors feedback into bit 6 in 7-bit mode" do
    apu =
      powered()
      |> APU.write(0xFF21, 0xF0)
      |> APU.write(0xFF22, 0x08)
      |> APU.write(0xFF23, 0x80)

    assert apu.ch4.timer == 8
    assert apu.ch4.lfsr == 0x7FFF

    advanced = APU.tick(apu, 8).ch4
    assert advanced.lfsr != 0x7FFF
    assert (advanced.lfsr >>> 6 &&& 1) == (advanced.lfsr >>> 14 &&& 1)

    for shift <- [14, 15] do
      frozen =
        powered()
        |> APU.write(0xFF21, 0xF0)
        |> APU.write(0xFF22, shift <<< 4)
        |> APU.write(0xFF23, 0x80)

      assert APU.tick(frozen, 300_000).ch4.lfsr == 0x7FFF
    end
  end

  test "batched noise clocks match scalar LFSR steps and arbitrarily split ticks" do
    cases = [
      {0, 0, 70_224},
      {0, 7, 70_224},
      {3, 2, 70_224},
      {6, 6, 70_224},
      {13, 7, (112 <<< 13) + 123}
    ]

    for width7 <- [false, true], {shift, divisor, dots} <- cases do
      width = if width7, do: 0x08, else: 0

      apu =
        powered()
        |> APU.write(0xFF21, 0xF0)
        |> APU.write(0xFF22, shift <<< 4 ||| width ||| divisor)
        |> APU.write(0xFF23, 0x80)

      period = elem({8, 16, 32, 48, 64, 80, 96, 112}, divisor) <<< shift
      expected_steps = div(dots, period)
      expected_lfsr = reference_lfsr(0x7FFF, expected_steps, width7)
      expected_timer = period - rem(dots, period)
      batched = APU.tick(apu, dots)

      chunked =
        Stream.cycle([1, 7, 31, 96, 257])
        |> Enum.reduce_while({apu, dots}, fn chunk, {apu, remaining} ->
          count = min(chunk, remaining)
          next = {APU.tick(apu, count), remaining - count}
          if count == remaining, do: {:halt, next}, else: {:cont, next}
        end)
        |> elem(0)

      assert batched.ch4.lfsr == expected_lfsr
      assert batched.ch4.timer == expected_timer
      assert chunked == batched
    end
  end

  test "NR51 routes channels independently into left and right signed PCM" do
    apu =
      powered()
      |> APU.write(0xFF16, 0xC0)
      |> APU.write(0xFF17, 0xF0)
      |> APU.write(0xFF18, 0)
      |> APU.write(0xFF19, 0x80)
      |> APU.write(0xFF24, 0)
      |> APU.write(0xFF25, 0x02)
      |> APU.tick(96)

    assert {1, <<0::little-signed-16, right::little-signed-16>>, apu} = APU.take_samples(apu)
    assert right > 0

    left = APU.write(apu, 0xFF25, 0x20)

    {1, <<left_sample::little-signed-16, right_tail::little-signed-16>>, _apu} =
      left |> APU.tick(95) |> APU.take_samples()

    assert left_sample > 0
    assert right_tail < 0
  end

  test "model controls powered-off length writes and is carried by mapped Bus" do
    dmg =
      APU.new(model: :dmg)
      |> APU.write(0xFF11, 0x3F)
      |> APU.write(0xFF16, 0x3E)
      |> APU.write(0xFF1B, 0xFF)
      |> APU.write(0xFF20, 0x3C)

    assert {dmg.ch1.length, dmg.ch2.length, dmg.ch3.length, dmg.ch4.length} == {1, 2, 1, 4}

    cgb =
      APU.new(model: :cgb)
      |> APU.write(0xFF11, 0x3F)
      |> APU.write(0xFF16, 0x3E)
      |> APU.write(0xFF1B, 0xFF)
      |> APU.write(0xFF20, 0x3C)

    assert {cgb.ch1.length, cgb.ch2.length, cgb.ch3.length, cgb.ch4.length} == {0, 0, 0, 0}
    assert_raise ArgumentError, fn -> APU.new(model: :invalid) end

    assert {:ok, dmg_machine} = Machine.load(rom(0))
    assert {:ok, cgb_machine} = Machine.load(rom(0x80))
    assert {dmg_machine.bus.apu.model, cgb_machine.bus.apu.model} == {:dmg, :cgb}
    assert {Bus.read(cgb_machine.bus, 0xFF76), Bus.read(cgb_machine.bus, 0xFF77)} == {0xFF, 0xFF}
  end

  test "integer sample accumulator has exact long-run count and drains once" do
    apu = APU.tick(APU.new(), @clock_rate)
    assert {44_100, pcm, drained} = APU.take_samples(apu)
    assert byte_size(pcm) == 44_100 * 4
    assert {0, <<>>, ^drained} = APU.take_samples(drained)

    split = APU.new() |> APU.tick(1_234_567) |> APU.tick(@clock_rate - 1_234_567)
    assert {44_100, ^pcm, _split} = APU.take_samples(split)
  end

  test "CGB output capacitor removes channel DC faster than DMG hardware" do
    dmg = constant_dac(:dmg) |> APU.tick(9_512)
    cgb = constant_dac(:cgb) |> APU.tick(9_512)

    assert {100, dmg_pcm, _dmg} = APU.take_samples(dmg)
    assert {100, cgb_pcm, _cgb} = APU.take_samples(cgb)

    assert {960, 960} = stereo_sample(dmg_pcm, 0)
    assert {960, 960} = stereo_sample(cgb_pcm, 0)
    assert elem(stereo_sample(cgb_pcm, 99), 0) == 0
    assert elem(stereo_sample(dmg_pcm, 99), 0) > 600
  end

  test "output capacitor is continuous across PCM drains and disconnects with every DAC off" do
    base = constant_dac(:cgb)
    whole = base |> APU.tick(19_025) |> APU.take_samples()

    {100, first_pcm, split} = base |> APU.tick(9_512) |> APU.take_samples()
    {100, second_pcm, split} = split |> APU.tick(9_513) |> APU.take_samples()
    split_pcm = first_pcm <> second_pcm
    assert {200, ^split_pcm, _whole} = whole

    disconnected = APU.write(split, 0xFF1A, 0) |> APU.tick(952)
    assert {10, disconnected_pcm, _disconnected} = APU.take_samples(disconnected)
    assert disconnected_pcm == :binary.copy(<<0>>, 40)
  end

  test "deferred advancement is identical at every observable APU boundary" do
    base =
      powered()
      |> APU.write(0xFF17, 0xF2)
      |> APU.write(0xFF18, 0xC0)
      |> APU.write(0xFF19, 0x87)
      |> APU.write(0xFF24, 0x77)
      |> APU.write(0xFF25, 0x22)

    eager = APU.tick(base, 20_000)

    deferred =
      base
      |> APU.defer_tick(4_001)
      |> APU.defer_tick(7_999)
      |> APU.defer_tick(8_000)

    assert APU.flush(deferred) == eager
    assert APU.read(APU.flush(deferred), 0xFF26) == APU.read(eager, 0xFF26)
    assert APU.write(APU.flush(deferred), 0xFF17, 0x91) == APU.write(eager, 0xFF17, 0x91)
    assert APU.take_samples(deferred) == APU.take_samples(eager)
  end

  test "Bus clocks APU in base dots, handles DIV falling edges, and preserves speed duration" do
    assert {:ok, normal} = Machine.load(rom(0x80))
    normal_bus = Bus.idle(normal.bus, 1_000)

    assert {:ok, double} = Machine.load(rom(0x80))
    {:speed_switch, double_bus} = double.bus |> Bus.write(0xFF4D, 1) |> Bus.stop()
    double_bus = Bus.idle(double_bus, 2_000)

    normal_apu = APU.flush(normal_bus.apu)
    double_apu = APU.flush(double_bus.apu)

    assert normal_apu.sample_phase == double_apu.sample_phase
    assert normal_apu.sample_count == double_apu.sample_count
    assert normal_apu.ch1.duty_pos == double_apu.ch1.duty_pos

    edge_apu =
      powered()
      |> APU.write(0xFF17, 0x19)
      |> APU.write(0xFF19, 0x80)
      |> Map.put(:sequencer_step, 7)

    edge_bus = %{normal.bus | apu: edge_apu, divider: 0x1000} |> Bus.write(0xFF04, 0)
    assert edge_bus.apu.ch2.volume == 2
    assert edge_bus.apu.sequencer_phase == 0

    {:speed_switch, double_edge_bus} = normal.bus |> Bus.write(0xFF4D, 1) |> Bus.stop()
    double_edge_bus = %{double_edge_bus | apu: edge_apu, divider: 0x1000}
    assert Bus.write(double_edge_bus, 0xFF04, 0).apu.ch2.volume == 1

    double_edge_bus = %{double_edge_bus | divider: 0x2000}
    assert Bus.write(double_edge_bus, 0xFF04, 0).apu.ch2.volume == 2

    switch_edge_bus = %{normal.bus | apu: edge_apu, divider: 0x1000} |> Bus.write(0xFF4D, 1)
    assert {:speed_switch, switched} = Bus.stop(switch_edge_bus)
    assert switched.apu.ch2.volume == 2
  end

  test "halt/DMA time advances audio while a stopped CPU consumes no device time" do
    assert {:ok, machine} = Machine.load(rom(0))
    halted = %{machine | cpu: %{machine.cpu | run_state: :halted}}
    {halted, 1} = Machine.step(halted)
    assert Bus.sync_apu(halted.bus).apu.sample_phase != machine.bus.apu.sample_phase

    dma_bus = Bus.write(machine.bus, 0xFF46, 0)
    {dma_bus, 160} = Bus.run_dma(dma_bus)
    assert Bus.sync_apu(dma_bus).apu.sample_count > machine.bus.apu.sample_count

    stopped = %{machine | cpu: %{machine.cpu | run_state: :stopped}}
    {stopped, 1} = Machine.step(stopped)
    assert stopped.bus.apu == machine.bus.apu
  end

  test "CPU register writes produce a machine-owned stereo audio stream" do
    program = <<
      0x3E,
      0x80,
      0xE0,
      0x26,
      0x3E,
      0x77,
      0xE0,
      0x24,
      0x3E,
      0x22,
      0xE0,
      0x25,
      0x3E,
      0x80,
      0xE0,
      0x16,
      0x3E,
      0xF0,
      0xE0,
      0x17,
      0x3E,
      0xFF,
      0xE0,
      0x18,
      0x3E,
      0x87,
      0xE0,
      0x19,
      0x18,
      0xFE
    >>

    assert {:ok, machine} = Machine.load(rom(0) |> put_bytes(0x100, program))
    machine = step_machine(machine, 14)
    assert Bus.read(machine.bus, 0xFF24) == 0x77
    assert Bus.read(machine.bus, 0xFF25) == 0x22
    assert (Bus.read(machine.bus, 0xFF26) &&& 0x02) != 0

    assert {:ok, machine, 0, _frame} = Machine.run_until_frame(machine)
    assert {count, pcm, bus} = Bus.take_audio_pcm(machine.bus)
    assert count > 0
    assert byte_size(pcm) == count * 4
    assert pcm != :binary.copy(<<0>>, byte_size(pcm))
    assert {0, <<>>, _bus} = Bus.take_audio_pcm(bus)
  end

  defp powered, do: power_on(APU.new())
  defp power_on(apu), do: APU.write(apu, 0xFF26, 0x80)

  defp constant_dac(model) do
    APU.new(model: model)
    |> power_on()
    |> APU.write(0xFF1A, 0x80)
    |> APU.write(0xFF1C, 0)
    |> APU.write(0xFF24, 0)
    |> APU.write(0xFF25, 0x44)
  end

  defp stereo_sample(pcm, index) do
    offset = index * 4

    <<_prefix::binary-size(^offset), left::little-signed-16, right::little-signed-16,
      _rest::binary>> = pcm

    {left, right}
  end

  defp sweep_ready(period, shift, frequency) do
    powered()
    |> APU.write(0xFF10, period <<< 4 ||| shift)
    |> APU.write(0xFF12, 0xF0)
    |> APU.write(0xFF13, frequency &&& 0xFF)
    |> APU.write(0xFF14, 0x80 ||| (frequency >>> 8 &&& 7))
    |> then(fn apu ->
      %{
        apu
        | sequencer_step: 2,
          ch1: %{
            apu.ch1
            | enabled: true,
              sweep_timer: 1,
              sweep_shadow: frequency,
              frequency: frequency
          }
      }
    end)
  end

  defp sweep_registers(apu), do: {elem(apu.registers, 3), elem(apu.registers, 4)}

  defp reference_lfsr(lfsr, 0, _width7), do: lfsr

  defp reference_lfsr(lfsr, steps, width7) do
    feedback = bxor(lfsr, lfsr >>> 1) &&& 1
    lfsr = lfsr >>> 1 ||| feedback <<< 14
    lfsr = if width7, do: (lfsr &&& bxor(0x40, 0x7FFF)) ||| feedback <<< 6, else: lfsr
    reference_lfsr(lfsr, steps - 1, width7)
  end

  defp step_machine(machine, 0), do: machine

  defp step_machine(machine, count) do
    {machine, _cycles} = Machine.step(machine)
    step_machine(machine, count - 1)
  end

  defp rom(cgb_flag) do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0x18, 0xFE>>)
    |> put_bytes(0x134, "APU TEST" <> :binary.copy(<<0>>, 8))
    |> put_byte(0x143, cgb_flag)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> with_checksum()
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
