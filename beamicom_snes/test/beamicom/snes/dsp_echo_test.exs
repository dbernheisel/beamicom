Code.require_file("../../../test_helpers/dsp_echo_reference_vectors.ex", __DIR__)

defmodule Beamicom.SNES.DSPEchoTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.DSP.Echo
  alias Beamicom.SNES.DSP.Echo.{Effect, State}
  alias Beamicom.SNES.DSPEchoReferenceVectors

  test "EON routes selected voices into an independently saturated echo bus" do
    assert Echo.route_voice({32_760, -32_760}, 0, {100, -100}, 0x01) ==
             {32_767, -32_768}

    assert Echo.route_voice({12, -34}, 1, {100, -100}, 0x01) == {12, -34}
  end

  test "eight FIR taps use oldest-to-newest history order" do
    vector = DSPEchoReferenceVectors.eight_tap_impulse()

    registers =
      DSPEchoReferenceVectors.registers(flg: 0x20)
      |> DSPEchoReferenceVectors.with_fir(vector.coefficients)

    state = State.new(history: vector.history)

    {state, _pcm, _effects} =
      Echo.process_sample(state, registers, {0, 0}, {0, 0}, vector.ram_sample)

    assert state.echo_input == vector.filtered
    assert elem(state.history, state.history_offset) == {80, -80}
  end

  test "FIR wraps taps zero through six before adding and clamping tap seven" do
    vector = DSPEchoReferenceVectors.clipped_fir()

    registers =
      DSPEchoReferenceVectors.registers(flg: 0x20)
      |> DSPEchoReferenceVectors.with_fir(vector.coefficients)

    state = State.new(history: vector.history)

    {state, _pcm, _effects} =
      Echo.process_sample(state, registers, {0, 0}, {0, 0}, vector.ram_sample)

    assert state.echo_input == vector.filtered
  end

  test "signed echo volume and feedback honor arithmetic shifts and clamp points" do
    assert Echo.mix(
             {32_767, -32_768},
             {16_000, -16_000},
             {-128, 127},
             {127, -128},
             :audible
           ) == {-16_892, -16_512}

    assert Echo.mix({1, 2}, {3, 4}, {127, 127}, {127, 127}, :muted) == {0, 0}

    assert Echo.feedback({30_000, -30_000}, {16_000, -16_000}, 127) ==
             {32_766, -32_768}

    assert Echo.feedback({0, 0}, {16_000, -16_000}, -128) == {-16_000, 16_000}
  end

  test "read effects stay scheduled while FLG disables both echo writes" do
    state = State.new(page: 0xFF, offset: 0xFC, length: 0x800)

    assert [
             %Effect{operation: :read, phase: 22, channel: :left, address: 0xFFFC},
             %Effect{operation: :read, phase: 23, channel: :right, address: 0xFFFE}
           ] = Echo.read_effects(state)

    registers = DSPEchoReferenceVectors.registers(flg: 0x20)
    {_state, _pcm, writes} = Echo.process_sample(state, registers, {0, 0}, {100, -100}, {0, 0})

    assert [
             %Effect{operation: :write, phase: 29, channel: :left, enabled?: false},
             %Effect{operation: :write, phase: 30, channel: :right, enabled?: false}
           ] = writes
  end

  test "echo addresses and little-endian RAM reads wrap at 16 bits" do
    state = State.new(page: 0xFF, offset: 0x0800, length: 0x1000)

    assert [%Effect{address: 0x0700}, %Effect{address: 0x0702}] = Echo.read_effects(state)
    assert Echo.decode_ram_sample(0xFE, 0xFF, 0x00, 0x80) == {-2, -32_768}
  end

  test "phase-specific FLG latches independently gate left and right writes" do
    state = State.new(page: 0x20, length: 0x800)
    registers = DSPEchoReferenceVectors.registers(efb: 0x7F)

    {_state, _pcm, writes} =
      Echo.process_sample(state, registers, {0, 0}, {200, -200}, {0, 0},
        flg_phase_28: 0x20,
        flg_phase_29: 0x00
      )

    assert [
             %Effect{channel: :left, enabled?: false, value: 200},
             %Effect{channel: :right, enabled?: true, value: -200}
           ] = writes
  end

  test "ESA is delayed one sample and EDL changes when the ring reaches offset zero" do
    registers = DSPEchoReferenceVectors.registers(esa: 0x34, edl: 0x02, flg: 0x20)
    state = State.new(page: 0x12, length: 0x800)

    assert [%Effect{address: 0x1200} | _] = Echo.read_effects(state)
    {state, _pcm, _writes} = Echo.process_sample(state, registers, {0, 0}, {0, 0}, {0, 0})

    assert state.page == 0x34
    assert state.length == 0x1000
    assert state.offset == 4
    assert [%Effect{address: 0x3404} | _] = Echo.read_effects(state)

    state = %{state | offset: 0x0FFC}
    registers = DSPEchoReferenceVectors.registers(esa: 0x34, edl: 0x01, flg: 0x20)
    {state, _pcm, _writes} = Echo.process_sample(state, registers, {0, 0}, {0, 0}, {0, 0})

    assert state.length == 0x1000
    assert state.offset == 0

    {state, _pcm, _writes} = Echo.process_sample(state, registers, {0, 0}, {0, 0}, {0, 0})
    assert state.length == 0x0800
    assert state.offset == 4
  end

  test "EDL zero continuously targets the first stereo frame" do
    registers = DSPEchoReferenceVectors.registers(esa: 0x40, edl: 0x00, flg: 0x00)
    state = State.new(page: 0x40, length: 0)

    {state, _pcm, writes} = Echo.process_sample(state, registers, {0, 0}, {2, -2}, {0, 0})

    assert state.offset == 0
    assert Enum.map(writes, & &1.address) == [0x4000, 0x4002]
    assert Enum.all?(writes, & &1.enabled?)
  end

  test "write effects apply signed little-endian samples with 16-bit address wrap" do
    ram = :array.new(0x10000, default: 0, fixed: true)

    effect = %Effect{
      operation: :write,
      phase: 29,
      channel: :left,
      address: 0xFFFF,
      value: -2,
      enabled?: true
    }

    ram = Echo.apply_write_effect(ram, effect)

    assert :array.get(0xFFFF, ram) == 0xFE
    assert :array.get(0x0000, ram) == 0xFF
  end

  test "inactive echo controls preserve the established scalar bypass" do
    registers = DSPEchoReferenceVectors.registers(flg: 0x20)

    refute Echo.scalar_required?(registers)
    assert Echo.controls(registers).fir == List.duplicate(0, 8)
  end

  test "echo controls expose signed volumes, feedback, and FIR coefficients" do
    registers =
      DSPEchoReferenceVectors.registers(
        evoll: 0x80,
        evolr: 0x7F,
        efb: 0xFF,
        eon: 0xA5,
        esa: 0x34,
        edl: 0xF2,
        flg: 0x20
      )
      |> DSPEchoReferenceVectors.with_fir([0x80, 0xFF, 0, 1, 2, 3, 0x7E, 0x7F])

    assert %{
             echo_volume: {-128, 127},
             feedback: -1,
             eon: 0xA5,
             page: 0x34,
             delay: 2,
             flg: 0x20,
             fir: [-128, -1, 0, 1, 2, 3, 126, 127]
           } = Echo.controls(registers)
  end

  test "configured echo requires scalar processing until an exact Nx kernel exists" do
    for {address, value} <- [
          {0x2C, 1},
          {0x3C, 1},
          {0x0D, 1},
          {0x4D, 1},
          {0x6D, 1},
          {0x7D, 1},
          {0x0F, 1}
        ] do
      registers = DSPEchoReferenceVectors.registers([{address, value}, {0x6C, 0x20}])
      assert Echo.scalar_required?(registers), "register #{Integer.to_string(address, 16)}"
    end
  end

  test "chunked processing produces the same state, PCM, and writes" do
    registers =
      DSPEchoReferenceVectors.registers(evoll: 0x7F, evolr: 0x7F, esa: 0x20, edl: 0x01)
      |> DSPEchoReferenceVectors.with_fir([0, 0, 0, 0, 0, 0, 0, 0x7F])

    samples = [{2_000, -2_000}, {4_000, -4_000}, {6_000, -6_000}]
    whole = Echo.process_samples(State.new(page: 0x20, length: 0x800), registers, samples)

    chunked =
      Enum.reduce(samples, {State.new(page: 0x20, length: 0x800), [], []}, fn sample,
                                                                              {state, pcm,
                                                                               effects} ->
        {state, output, sample_effects} =
          Echo.process_sample(state, registers, {0, 0}, {0, 0}, sample)

        {state, [output | pcm], [sample_effects | effects]}
      end)
      |> then(fn {state, pcm, effects} ->
        {state, Enum.reverse(pcm), effects |> Enum.reverse() |> List.flatten()}
      end)

    assert whole == chunked
  end
end
