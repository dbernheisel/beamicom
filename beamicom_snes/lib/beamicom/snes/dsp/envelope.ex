defmodule Beamicom.SNES.DSP.Envelope do
  @moduledoc false

  import Bitwise

  @release 0
  @attack 1
  @decay 2
  @sustain 3
  @counter_range 30_720
  @counter_rates {
    30_721,
    2_048,
    1_536,
    1_280,
    1_024,
    768,
    640,
    512,
    384,
    320,
    256,
    192,
    160,
    128,
    96,
    80,
    64,
    48,
    40,
    32,
    24,
    20,
    16,
    12,
    10,
    8,
    6,
    5,
    4,
    3,
    2,
    1
  }
  @counter_offsets {
    1,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    536,
    0,
    1_040,
    0,
    0
  }

  def release, do: @release
  def attack, do: @attack
  def decay, do: @decay
  def sustain, do: @sustain
  def counter_rates, do: Tuple.to_list(@counter_rates)
  def counter_offsets, do: Tuple.to_list(@counter_offsets)
  def next_counter(0), do: @counter_range - 1
  def next_counter(counter), do: counter - 1
  def advance_counter(counter, frames), do: Integer.mod(counter - frames, @counter_range)

  def advance(active?, envelope, @release, hidden_envelope, _adsr1, _adsr2, _gain, _counter) do
    envelope = max(envelope - 8, 0)
    {active? and envelope > 0, envelope, @release, hidden_envelope}
  end

  def advance(active?, envelope, mode, hidden_envelope, adsr1, adsr2, gain, counter) do
    {next_envelope, rate} =
      next_envelope(envelope, mode, hidden_envelope, adsr1, adsr2, gain)

    mode = next_mode(next_envelope, mode, adsr1, adsr2)
    hidden_envelope = next_envelope
    {next_envelope, mode} = clamp_envelope(next_envelope, mode)
    envelope = if counter_tick?(counter, rate), do: next_envelope, else: envelope
    {active?, envelope, mode, hidden_envelope}
  end

  defp next_envelope(envelope, mode, _hidden, adsr1, adsr2, _gain)
       when (adsr1 &&& 0x80) != 0 do
    if mode >= @decay do
      rate = if mode == @decay, do: (adsr1 >>> 3 &&& 0x0E) + 0x10, else: adsr2 &&& 0x1F
      {envelope - 1 - (envelope >>> 8), rate}
    else
      rate = (adsr1 &&& 0x0F) * 2 + 1
      {envelope + if(rate < 31, do: 0x20, else: 0x400), rate}
    end
  end

  defp next_envelope(envelope, _mode, hidden, _adsr1, _adsr2, gain) do
    mode = gain >>> 5
    rate = gain &&& 0x1F

    case mode do
      direct when direct < 4 -> {gain * 0x10, 31}
      4 -> {envelope - 0x20, rate}
      5 -> {envelope - 1 - (envelope >>> 8), rate}
      6 -> {envelope + 0x20, rate}
      7 -> {envelope + if(hidden >= 0x600, do: 0x08, else: 0x20), rate}
    end
  end

  defp next_mode(envelope, @decay, adsr1, adsr2)
       when (adsr1 &&& 0x80) != 0 and envelope >>> 8 == adsr2 >>> 5,
       do: @sustain

  defp next_mode(_envelope, mode, _adsr1, _adsr2), do: mode

  defp clamp_envelope(envelope, @attack) when envelope > 0x7FF, do: {0x7FF, @decay}
  defp clamp_envelope(envelope, mode), do: {min(max(envelope, 0), 0x7FF), mode}

  defp counter_tick?(counter, rate),
    do: rem(counter + elem(@counter_offsets, rate), elem(@counter_rates, rate)) == 0
end
