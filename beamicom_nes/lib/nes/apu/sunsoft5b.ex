defmodule Beamicom.NES.APU.Sunsoft5B do
  @moduledoc false

  import Bitwise

  @volume_table List.to_tuple(
                  for level <- 0..31 do
                    if level < 2, do: 0.0, else: :math.pow(10.0, (level - 31) * 1.5 / 20.0)
                  end
                )

  defstruct selected: nil,
            regs: {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            tone_div: 0,
            tone_counters: {0, 0, 0},
            tone_levels: 0,
            noise_div: 0,
            noise_counter: 0,
            noise_lfsr: 0x1FFFF,
            envelope_div: 0,
            envelope_counter: 0,
            envelope_level: 31,
            envelope_direction: -1,
            envelope_holding: false

  def select(state, value),
    do: %{state | selected: if((value &&& 0xF0) == 0, do: value &&& 0x0F, else: nil)}

  def write(%__MODULE__{selected: nil} = state, _value), do: state

  def write(%__MODULE__{selected: reg} = state, value) do
    value = mask(reg, value)
    state = %{state | regs: put_elem(state.regs, reg, value)}

    if reg == 13 do
      attack = (value &&& 0x04) != 0

      %{
        state
        | envelope_counter: 0,
          envelope_level: if(attack, do: 0, else: 31),
          envelope_direction: if(attack, do: 1, else: -1),
          envelope_holding: false
      }
    else
      state
    end
  end

  def advance(state, cycles) do
    tone_total = state.tone_div + cycles
    noise_total = state.noise_div + cycles
    envelope_total = state.envelope_div + cycles

    state
    |> Map.put(:tone_div, rem(tone_total, 16))
    |> advance_tones(div(tone_total, 16))
    |> Map.put(:noise_div, rem(noise_total, 32))
    |> advance_noise(div(noise_total, 32))
    |> Map.put(:envelope_div, rem(envelope_total, 16))
    |> advance_envelope(div(envelope_total, 16))
  end

  def output(state) do
    mixer = elem(state.regs, 7)

    Enum.reduce(0..2, 0.0, fn channel, sum ->
      tone_on = (mixer &&& 1 <<< channel) != 0 or (state.tone_levels &&& 1 <<< channel) != 0
      noise_on = (mixer &&& 1 <<< (channel + 3)) != 0 or (state.noise_lfsr &&& 1) != 0

      if tone_on and noise_on do
        volume = elem(state.regs, 8 + channel)
        level = if((volume &&& 0x10) != 0, do: state.envelope_level, else: fixed_level(volume))
        sum + elem(@volume_table, level)
      else
        sum
      end
    end) * 0.25
  end

  defp advance_tones(state, 0), do: state

  defp advance_tones(state, ticks) do
    {counters, levels} =
      Enum.reduce(0..2, {state.tone_counters, state.tone_levels}, fn channel,
                                                                     {counters, levels} ->
        period = tone_period(state.regs, channel)
        total = elem(counters, channel) + ticks
        flips = div(total, period)
        counters = put_elem(counters, channel, rem(total, period))
        levels = if rem(flips, 2) == 1, do: bxor(levels, 1 <<< channel), else: levels
        {counters, levels}
      end)

    %{state | tone_counters: counters, tone_levels: levels}
  end

  defp advance_noise(state, 0), do: state

  defp advance_noise(state, ticks) do
    period = max(elem(state.regs, 6), 1)
    total = state.noise_counter + ticks
    steps = div(total, period)
    %{state | noise_counter: rem(total, period), noise_lfsr: noise_steps(state.noise_lfsr, steps)}
  end

  defp noise_steps(lfsr, 0), do: lfsr

  defp noise_steps(lfsr, steps) do
    feedback = bxor(lfsr >>> 16, lfsr >>> 13) &&& 1
    noise_steps((lfsr <<< 1 &&& 0x1FFFF) ||| feedback, steps - 1)
  end

  defp advance_envelope(%{envelope_holding: true} = state, _ticks), do: state
  defp advance_envelope(state, 0), do: state

  defp advance_envelope(state, ticks) do
    period = max(elem(state.regs, 11) ||| elem(state.regs, 12) <<< 8, 1)
    total = state.envelope_counter + ticks
    steps = div(total, period)

    %{state | envelope_counter: rem(total, period)}
    |> envelope_steps(steps)
  end

  defp envelope_steps(state, 0), do: state
  defp envelope_steps(%{envelope_holding: true} = state, _steps), do: state

  defp envelope_steps(state, steps) do
    next = state.envelope_level + state.envelope_direction

    state =
      if next in 0..31 do
        %{state | envelope_level: next}
      else
        envelope_boundary(state)
      end

    envelope_steps(state, steps - 1)
  end

  defp envelope_boundary(state) do
    shape = elem(state.regs, 13)
    continue? = (shape &&& 0x08) != 0
    alternate? = (shape &&& 0x02) != 0
    hold? = (shape &&& 0x01) != 0

    cond do
      not continue? ->
        %{state | envelope_level: 0, envelope_holding: true}

      hold? ->
        level = if(alternate?, do: 31 - state.envelope_level, else: state.envelope_level)
        %{state | envelope_level: level, envelope_holding: true}

      alternate? ->
        direction = -state.envelope_direction
        %{state | envelope_direction: direction, envelope_level: state.envelope_level + direction}

      state.envelope_direction > 0 ->
        %{state | envelope_level: 0}

      true ->
        %{state | envelope_level: 31}
    end
  end

  defp tone_period(regs, channel) do
    max(elem(regs, channel * 2) ||| (elem(regs, channel * 2 + 1) &&& 0x0F) <<< 8, 1)
  end

  defp fixed_level(volume) do
    value = volume &&& 0x0F
    if value == 0, do: 0, else: value * 2 + 1
  end

  defp mask(reg, value) when reg in [1, 3, 5], do: value &&& 0x0F
  defp mask(6, value), do: value &&& 0x1F
  defp mask(7, value), do: value &&& 0x3F
  defp mask(reg, value) when reg in 8..10, do: value &&& 0x1F
  defp mask(13, value), do: value &&& 0x0F
  defp mask(_reg, value), do: value &&& 0xFF
end
