defmodule Beamicom.SNES.DSP.Echo do
  @moduledoc """
  Immutable S-DSP echo/FIR unit with phase-tagged shared-RAM effects.

  The arithmetic and phases follow the independently maintained accurate DSPs
  in [Blargg's `snes_spc`](https://github.com/blarggs-audio-libraries/snes_spc/blob/master/snes_spc/SPC_DSP.cpp#L558-L704)
  and [ares](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/echo.cpp).

  `read_effects/1` exposes the phase-22/23 RAM reads. The shared APU timeline
  resolves those reads and passes the signed stereo result to
  `process_sample/6`, which returns phase-29/30 write effects. This module never
  owns or snapshots shared APU RAM.
  """

  import Bitwise

  alias Beamicom.SNES.APU.RAM
  alias Beamicom.SNES.DSP.{Arithmetic, Mixer}
  alias Beamicom.SNES.DSP.Echo.{Effect, State}

  @echo_registers [
    0x2C,
    0x3C,
    0x0D,
    0x4D,
    0x6D,
    0x7D,
    0x0F,
    0x1F,
    0x2F,
    0x3F,
    0x4F,
    0x5F,
    0x6F,
    0x7F
  ]

  def accumulate(bus, contribution), do: Mixer.accumulate(bus, contribution)

  def route_voice(bus, index, contribution, eon) when index in 0..7 do
    if (eon &&& 1 <<< index) != 0, do: accumulate(bus, contribution), else: bus
  end

  def controls(registers) do
    %{
      echo_volume: {signed_register(registers, 0x2C), signed_register(registers, 0x3C)},
      feedback: signed_register(registers, 0x0D),
      eon: register(registers, 0x4D),
      page: register(registers, 0x6D),
      delay: register(registers, 0x7D) &&& 0x0F,
      fir: for(index <- 0..7, do: signed_register(registers, 0x0F + index * 0x10)),
      flg: register(registers, 0x6C)
    }
  end

  def scalar_required?(registers) do
    Enum.any?(@echo_registers, &(register(registers, &1) != 0))
  end

  def read_effects(%State{} = state) do
    {left_address, right_address} = read_addresses(state)

    [
      %Effect{operation: :read, phase: 22, channel: :left, address: left_address},
      %Effect{operation: :read, phase: 23, channel: :right, address: right_address}
    ]
  end

  @doc false
  def read_addresses(%State{} = state) do
    address = echo_address(state)
    {address, wrap16(address + 2)}
  end

  def process_sample(
        %State{} = state,
        registers,
        main_bus,
        echo_bus,
        ram_sample,
        opts \\ []
      ) do
    {state, pcm, {left_write, right_write}} =
      process_sample_transition(state, registers, main_bus, echo_bus, ram_sample, opts)

    effects = [
      effect_from_write(:left, 29, left_write),
      effect_from_write(:right, 30, right_write)
    ]

    {state, pcm, effects}
  end

  @doc false
  def process_sample_transition(
        %State{} = state,
        registers,
        main_bus,
        echo_bus,
        ram_sample,
        opts \\ []
      ) do
    {echo_volume, feedback, page, delay, fir, flg} = sample_controls(registers)
    history_offset = rem(state.history_offset + 1, 8)
    history = put_elem(state.history, history_offset, halve_ram_sample(ram_sample))
    echo_input = filter(history, history_offset, fir)

    muted =
      if Keyword.get(opts, :muted?, (flg &&& 0x40) != 0),
        do: :muted,
        else: :audible

    pcm = mix(main_bus, echo_input, main_volume(registers), echo_volume, muted)
    feedback_output = feedback(echo_bus, echo_input, feedback)
    address = echo_address(state)
    flg_phase_28 = Keyword.get(opts, :flg_phase_28, flg)
    flg_phase_29 = Keyword.get(opts, :flg_phase_29, flg)

    writes = {
      {address, elem(feedback_output, 0), (flg_phase_28 &&& 0x20) == 0},
      {wrap16(address + 2), elem(feedback_output, 1), (flg_phase_29 &&& 0x20) == 0}
    }

    state = advance_ring(state, page, delay, history, history_offset, echo_input, feedback_output)
    {state, pcm, writes}
  end

  def process_samples(%State{} = state, registers, ram_samples, opts \\ []) do
    Enum.reduce(ram_samples, {state, [], []}, fn ram_sample, {state, pcm, effects} ->
      {state, output, sample_effects} =
        process_sample(state, registers, {0, 0}, {0, 0}, ram_sample, opts)

      {state, [output | pcm], [sample_effects | effects]}
    end)
    |> then(fn {state, pcm, effects} ->
      {state, Enum.reverse(pcm), effects |> Enum.reverse() |> List.flatten()}
    end)
  end

  def mix(_main_bus, _echo_input, _main_volume, _echo_volume, :muted), do: {0, 0}

  def mix(
        {main_left, main_right},
        {echo_left, echo_right},
        {main_volume_left, main_volume_right},
        {echo_volume_left, echo_volume_right},
        :audible
      ) do
    {
      mix_channel(main_left, echo_left, main_volume_left, echo_volume_left),
      mix_channel(main_right, echo_right, main_volume_right, echo_volume_right)
    }
  end

  def feedback({echo_left, echo_right}, {input_left, input_right}, feedback) do
    {
      feedback_channel(echo_left, input_left, feedback),
      feedback_channel(echo_right, input_right, feedback)
    }
  end

  def apply_write_effect(ram, %Effect{operation: :write, enabled?: false}), do: ram

  def apply_write_effect(ram, %Effect{operation: :write, enabled?: true} = effect) do
    apply_write(ram, {effect.address, effect.value, true})
  end

  @doc false
  def apply_write(ram, {_address, _value, false}), do: ram

  def apply_write(ram, {address, value, true}) do
    value = value &&& 0xFFFF

    ram
    |> then(&RAM.put(&1, address, value &&& 0xFF))
    |> then(&RAM.put(&1, wrap16(address + 1), value >>> 8))
  end

  def decode_ram_sample(left_low, left_high, right_low, right_high) do
    {
      Arithmetic.signed16(left_low ||| left_high <<< 8),
      Arithmetic.signed16(right_low ||| right_high <<< 8)
    }
  end

  defp filter(history, history_offset, coefficients) do
    left = filter_channel(history, history_offset, coefficients, 0)
    right = filter_channel(history, history_offset, coefficients, 1)
    {left, right}
  end

  defp filter_channel(history, history_offset, coefficients, channel) do
    tap0 = filter_tap(history, history_offset, coefficients, channel, 0)
    tap1 = filter_tap(history, history_offset, coefficients, channel, 1)
    tap2 = filter_tap(history, history_offset, coefficients, channel, 2)
    tap3 = filter_tap(history, history_offset, coefficients, channel, 3)
    tap4 = filter_tap(history, history_offset, coefficients, channel, 4)
    tap5 = filter_tap(history, history_offset, coefficients, channel, 5)
    tap6 = filter_tap(history, history_offset, coefficients, channel, 6)
    tap7 = filter_tap(history, history_offset, coefficients, channel, 7)

    first_seven =
      (tap0 + tap1 + tap2 + tap3 + tap4 + tap5 + tap6)
      |> Arithmetic.signed16()

    tap_seven = Arithmetic.signed16(tap7)

    first_seven
    |> Kernel.+(tap_seven)
    |> Arithmetic.clamp16()
    |> band(bnot(1))
  end

  defp filter_tap(history, history_offset, coefficients, channel, index) do
    sample = history |> elem(rem(history_offset + index + 1, 8)) |> elem(channel)
    Arithmetic.shift_right(sample * elem(coefficients, index), 6)
  end

  defp mix_channel(main, echo, main_volume, echo_volume) do
    main = main |> Kernel.*(main_volume) |> Arithmetic.shift_right(7) |> Arithmetic.signed16()
    echo = echo |> Kernel.*(echo_volume) |> Arithmetic.shift_right(7) |> Arithmetic.signed16()
    Arithmetic.clamp16(main + echo)
  end

  defp feedback_channel(echo, input, feedback) do
    feedback = input |> Kernel.*(feedback) |> Arithmetic.shift_right(7) |> Arithmetic.signed16()

    echo
    |> Kernel.+(feedback)
    |> Arithmetic.clamp16()
    |> band(bnot(1))
  end

  defp halve_ram_sample({left, right}) do
    {
      left |> Arithmetic.signed16() |> Arithmetic.shift_right(1),
      right |> Arithmetic.signed16() |> Arithmetic.shift_right(1)
    }
  end

  defp advance_ring(
         %State{} = state,
         page,
         delay,
         history,
         history_offset,
         echo_input,
         feedback_output
       ) do
    length = if state.offset == 0, do: delay * 0x800, else: state.length
    offset = state.offset + 4
    offset = if offset >= length, do: 0, else: offset

    %State{
      state
      | history: history,
        history_offset: history_offset,
        page: page,
        offset: offset,
        length: length,
        echo_input: echo_input,
        feedback_output: feedback_output
    }
  end

  defp effect_from_write(channel, phase, {address, value, enabled?}) do
    %Effect{
      operation: :write,
      phase: phase,
      channel: channel,
      address: address,
      value: value,
      enabled?: enabled?
    }
  end

  defp sample_controls(registers) do
    {
      {signed_register(registers, 0x2C), signed_register(registers, 0x3C)},
      signed_register(registers, 0x0D),
      register(registers, 0x6D),
      register(registers, 0x7D) &&& 0x0F,
      {
        signed_register(registers, 0x0F),
        signed_register(registers, 0x1F),
        signed_register(registers, 0x2F),
        signed_register(registers, 0x3F),
        signed_register(registers, 0x4F),
        signed_register(registers, 0x5F),
        signed_register(registers, 0x6F),
        signed_register(registers, 0x7F)
      },
      register(registers, 0x6C)
    }
  end

  defp main_volume(registers),
    do: {signed_register(registers, 0x0C), signed_register(registers, 0x1C)}

  defp echo_address(state), do: wrap16((state.page <<< 8) + state.offset)

  defp signed_register(registers, address),
    do: registers |> register(address) |> Arithmetic.signed8()

  defp register(registers, address), do: elem(registers, address)
  defp wrap16(value), do: value &&& 0xFFFF
end
