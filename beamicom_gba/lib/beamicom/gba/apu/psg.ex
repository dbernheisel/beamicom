defmodule Beamicom.GBA.APU.PSG do
  @moduledoc false

  import Bitwise

  @sequencer_period 32_768
  @blank_wave :binary.copy(<<0>>, 32)
  @noise_divisors {32, 64, 128, 192, 256, 320, 384, 448}
  @duty_rows {
    {0, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 1, 1, 1},
    {0, 1, 1, 1, 1, 1, 1, 0}
  }
  @dac_levels {15, 13, 11, 9, 7, 5, 3, 1, -1, -3, -5, -7, -9, -11, -13, -15}

  @pulse %{
    enabled: false,
    dac: false,
    length: 0,
    length_enable: false,
    duty: 0,
    duty_pos: 0,
    frequency: 0,
    timer: 16,
    initial_volume: 0,
    volume: 0,
    envelope_add: false,
    envelope_period: 0,
    envelope_timer: 8,
    sweep_period: 0,
    sweep_negate: false,
    sweep_shift: 0,
    sweep_timer: 8,
    sweep_shadow: 0,
    sweep_enabled: false
  }
  @wave %{
    enabled: false,
    dac: false,
    dimension: false,
    bank: 0,
    length: 0,
    length_enable: false,
    level: 0,
    force_volume: false,
    frequency: 0,
    timer: 8,
    position: 0,
    sample_buffer: 0
  }
  @noise %{
    enabled: false,
    dac: false,
    length: 0,
    length_enable: false,
    initial_volume: 0,
    volume: 0,
    envelope_add: false,
    envelope_period: 0,
    envelope_timer: 8,
    shift: 0,
    width7: false,
    divisor: 0,
    timer: 32,
    lfsr: 0x7FFF
  }

  defstruct master: false,
            soundcnt_l: 0,
            soundcnt_h: 0,
            wave_ram: @blank_wave,
            ch1: @pulse,
            ch2: @pulse,
            ch3: @wave,
            ch4: @noise,
            sequencer_phase: 0,
            sequencer_step: 0,
            cycle: 0

  @type t :: %__MODULE__{}

  def new(cycle \\ 0) when is_integer(cycle) and cycle >= 0, do: %__MODULE__{cycle: cycle}

  def status(%__MODULE__{} = psg) do
    channel_status(psg.ch1, 0) ||| channel_status(psg.ch2, 1) |||
      channel_status(psg.ch3, 2) ||| channel_status(psg.ch4, 3)
  end

  def advance_to(%__MODULE__{cycle: cycle} = psg, cycle), do: psg

  def advance_to(%__MODULE__{cycle: cycle} = psg, target) when target > cycle do
    advance(psg, target - cycle)
  end

  def write(%__MODULE__{} = psg, 0x84, value) do
    enabled? = bit?(value, 7)

    cond do
      enabled? and not psg.master ->
        %{psg | master: true, sequencer_phase: 0, sequencer_step: 0}

      not enabled? and psg.master ->
        power_off(psg)

      true ->
        psg
    end
  end

  def write(%__MODULE__{} = psg, 0x82, value),
    do: %{psg | soundcnt_h: (psg.soundcnt_h &&& 0xFF00) ||| (value &&& 0x03)}

  def write(%__MODULE__{} = psg, 0x83, value),
    do: %{psg | soundcnt_h: (psg.soundcnt_h &&& 0x00FF) ||| (value &&& 0x77) <<< 8}

  def write(%__MODULE__{} = psg, offset, value) when offset in 0x90..0x9F do
    bank = bxor(psg.ch3.bank, 1)
    wave_ram = put_byte(psg.wave_ram, bank * 16 + offset - 0x90, value)
    %{psg | wave_ram: wave_ram}
  end

  def write(%__MODULE__{master: false} = psg, _offset, _value), do: psg

  def write(%__MODULE__{} = psg, 0x60, value) do
    ch = %{
      psg.ch1
      | sweep_period: value >>> 4 &&& 7,
        sweep_negate: bit?(value, 3),
        sweep_shift: value &&& 7
    }

    %{psg | ch1: ch}
  end

  def write(%__MODULE__{} = psg, 0x62, value) do
    ch = %{psg.ch1 | duty: value >>> 6, length: 64 - (value &&& 0x3F)}
    %{psg | ch1: ch}
  end

  def write(%__MODULE__{} = psg, 0x63, value), do: write_envelope(psg, :ch1, value)
  def write(%__MODULE__{} = psg, 0x64, value), do: write_frequency_low(psg, :ch1, value)
  def write(%__MODULE__{} = psg, 0x65, value), do: write_frequency_high(psg, :ch1, value)

  def write(%__MODULE__{} = psg, 0x68, value) do
    ch = %{psg.ch2 | duty: value >>> 6, length: 64 - (value &&& 0x3F)}
    %{psg | ch2: ch}
  end

  def write(%__MODULE__{} = psg, 0x69, value), do: write_envelope(psg, :ch2, value)
  def write(%__MODULE__{} = psg, 0x6C, value), do: write_frequency_low(psg, :ch2, value)
  def write(%__MODULE__{} = psg, 0x6D, value), do: write_frequency_high(psg, :ch2, value)

  def write(%__MODULE__{} = psg, 0x70, value) do
    ch = %{
      psg.ch3
      | dac: bit?(value, 7),
        enabled: psg.ch3.enabled and bit?(value, 7),
        dimension: bit?(value, 5),
        bank: value >>> 6 &&& 1
    }

    %{psg | ch3: ch}
  end

  def write(%__MODULE__{} = psg, 0x72, value),
    do: %{psg | ch3: %{psg.ch3 | length: 256 - value}}

  def write(%__MODULE__{} = psg, 0x73, value) do
    ch = %{psg.ch3 | level: value >>> 5 &&& 3, force_volume: bit?(value, 7)}
    %{psg | ch3: ch}
  end

  def write(%__MODULE__{} = psg, 0x74, value) do
    ch = %{psg.ch3 | frequency: (psg.ch3.frequency &&& 0x700) ||| value}
    %{psg | ch3: ch}
  end

  def write(%__MODULE__{} = psg, 0x75, value) do
    frequency = (psg.ch3.frequency &&& 0xFF) ||| (value &&& 7) <<< 8
    ch = update_length_enable(%{psg.ch3 | frequency: frequency}, value, psg.sequencer_step)
    ch = if bit?(value, 7), do: trigger_wave(ch, psg.wave_ram, psg.sequencer_step), else: ch
    %{psg | ch3: ch}
  end

  def write(%__MODULE__{} = psg, 0x78, value),
    do: %{psg | ch4: %{psg.ch4 | length: 64 - (value &&& 0x3F)}}

  def write(%__MODULE__{} = psg, 0x79, value), do: write_envelope(psg, :ch4, value)

  def write(%__MODULE__{} = psg, 0x7C, value) do
    ch = %{
      psg.ch4
      | shift: value >>> 4,
        width7: bit?(value, 3),
        divisor: value &&& 7
    }

    %{psg | ch4: ch}
  end

  def write(%__MODULE__{} = psg, 0x7D, value) do
    ch = update_length_enable(psg.ch4, value, psg.sequencer_step)
    ch = if bit?(value, 7), do: trigger_noise(ch, psg.sequencer_step), else: ch
    %{psg | ch4: ch}
  end

  def write(%__MODULE__{} = psg, 0x80, value),
    do: %{psg | soundcnt_l: (psg.soundcnt_l &&& 0xFF00) ||| (value &&& 0x77)}

  def write(%__MODULE__{} = psg, 0x81, value),
    do: %{psg | soundcnt_l: (psg.soundcnt_l &&& 0x00FF) ||| value <<< 8}

  def write(%__MODULE__{} = psg, _offset, _value), do: psg

  def mix(%__MODULE__{master: false}), do: {0, 0}

  def mix(%__MODULE__{} = psg) do
    outputs =
      {pulse_output(psg.ch1), pulse_output(psg.ch2), wave_output(psg.ch3), noise_output(psg.ch4)}

    right_routes = psg.soundcnt_l >>> 8 &&& 0x0F
    left_routes = psg.soundcnt_l >>> 12 &&& 0x0F
    right_volume = (psg.soundcnt_l &&& 7) + 1
    left_volume = (psg.soundcnt_l >>> 4 &&& 7) + 1
    ratio = elem({1, 2, 4, 0}, psg.soundcnt_h &&& 3)
    right = routed_sum(outputs, right_routes) * right_volume * ratio * 8
    left = routed_sum(outputs, left_routes) * left_volume * ratio * 8
    {left, right}
  end

  defp advance(psg, 0), do: psg

  defp advance(psg, cycles) do
    distance = min(cycles, @sequencer_period - psg.sequencer_phase)

    psg =
      if psg.master do
        advance_channels(psg, distance)
      else
        psg
      end

    phase = psg.sequencer_phase + distance
    psg = %{psg | sequencer_phase: phase, cycle: psg.cycle + distance}

    psg =
      if phase == @sequencer_period do
        psg = %{psg | sequencer_phase: 0}
        if psg.master, do: clock_frame_sequencer(psg), else: psg
      else
        psg
      end

    advance(psg, cycles - distance)
  end

  defp advance_channels(psg, cycles) do
    %{
      psg
      | ch1: advance_pulse(psg.ch1, cycles),
        ch2: advance_pulse(psg.ch2, cycles),
        ch3: advance_wave(psg.ch3, psg.wave_ram, cycles),
        ch4: advance_noise(psg.ch4, cycles)
    }
  end

  defp advance_pulse(%{enabled: false} = ch, _cycles), do: ch
  defp advance_pulse(ch, cycles) when cycles < ch.timer, do: %{ch | timer: ch.timer - cycles}

  defp advance_pulse(ch, cycles) do
    period = pulse_period(ch.frequency)
    after_first = cycles - ch.timer
    steps = 1 + div(after_first, period)
    remainder = rem(after_first, period)
    timer = if remainder == 0, do: period, else: period - remainder
    %{ch | timer: timer, duty_pos: ch.duty_pos + steps &&& 7}
  end

  defp advance_wave(%{enabled: false} = ch, _wave_ram, _cycles), do: ch

  defp advance_wave(ch, _wave_ram, cycles) when cycles < ch.timer,
    do: %{ch | timer: ch.timer - cycles}

  defp advance_wave(ch, wave_ram, cycles) do
    period = wave_period(ch.frequency)
    after_first = cycles - ch.timer
    steps = 1 + div(after_first, period)
    remainder = rem(after_first, period)
    timer = if remainder == 0, do: period, else: period - remainder
    position = wave_position(ch, steps)
    %{ch | timer: timer, position: position, sample_buffer: wave_sample(wave_ram, position)}
  end

  defp advance_noise(%{enabled: false} = ch, _cycles), do: ch
  defp advance_noise(ch, cycles) when cycles < ch.timer, do: %{ch | timer: ch.timer - cycles}

  defp advance_noise(ch, cycles) do
    period = noise_period(ch)
    after_first = cycles - ch.timer
    steps = 1 + div(after_first, period)
    remainder = rem(after_first, period)
    timer = if remainder == 0, do: period, else: period - remainder
    %{ch | timer: timer, lfsr: advance_lfsr(ch.lfsr, steps, ch.width7)}
  end

  defp advance_lfsr(lfsr, 0, _width7), do: lfsr

  defp advance_lfsr(lfsr, steps, width7) do
    feedback = bxor(lfsr, lfsr >>> 1) &&& 1
    lfsr = lfsr >>> 1 ||| feedback <<< 14
    lfsr = if width7, do: (lfsr &&& bnot(0x40)) ||| feedback <<< 6, else: lfsr
    advance_lfsr(lfsr, steps - 1, width7)
  end

  defp clock_frame_sequencer(psg) do
    step = psg.sequencer_step
    psg = if step in [0, 2, 4, 6], do: clock_lengths(psg), else: psg
    psg = if step in [2, 6], do: clock_sweep(psg), else: psg
    psg = if step == 7, do: clock_envelopes(psg), else: psg
    %{psg | sequencer_step: step + 1 &&& 7}
  end

  defp clock_lengths(psg) do
    %{
      psg
      | ch1: clock_length(psg.ch1),
        ch2: clock_length(psg.ch2),
        ch3: clock_length(psg.ch3),
        ch4: clock_length(psg.ch4)
    }
  end

  defp clock_length(%{length_enable: true, length: 1} = ch),
    do: %{ch | length: 0, enabled: false}

  defp clock_length(%{length_enable: true, length: length} = ch) when length > 1,
    do: %{ch | length: length - 1}

  defp clock_length(ch), do: ch

  defp clock_envelopes(psg) do
    %{
      psg
      | ch1: clock_envelope(psg.ch1),
        ch2: clock_envelope(psg.ch2),
        ch4: clock_envelope(psg.ch4)
    }
  end

  defp clock_envelope(%{enabled: false} = ch), do: ch
  defp clock_envelope(%{envelope_period: 0} = ch), do: ch

  defp clock_envelope(%{envelope_timer: timer} = ch) when timer > 1,
    do: %{ch | envelope_timer: timer - 1}

  defp clock_envelope(ch) do
    next = if ch.envelope_add, do: ch.volume + 1, else: ch.volume - 1
    volume = if next in 0..15, do: next, else: ch.volume
    %{ch | volume: volume, envelope_timer: envelope_reload(ch.envelope_period)}
  end

  defp clock_sweep(%{ch1: %{sweep_enabled: false}} = psg), do: psg

  defp clock_sweep(%{ch1: %{sweep_timer: timer} = ch} = psg) when timer > 1,
    do: %{psg | ch1: %{ch | sweep_timer: timer - 1}}

  defp clock_sweep(%{ch1: ch} = psg) do
    ch = %{ch | sweep_timer: max(ch.sweep_period, 1)}
    frequency = sweep_frequency(ch)

    cond do
      frequency > 0x7FF ->
        %{psg | ch1: %{ch | enabled: false}}

      ch.sweep_shift == 0 ->
        %{psg | ch1: ch}

      true ->
        ch = %{ch | frequency: frequency, sweep_shadow: frequency}
        ch = if sweep_frequency(ch) > 0x7FF, do: %{ch | enabled: false}, else: ch
        %{psg | ch1: ch}
    end
  end

  defp write_envelope(psg, channel, value) do
    ch = Map.fetch!(psg, channel)
    dac = (value &&& 0xF8) != 0

    ch = %{
      ch
      | dac: dac,
        enabled: ch.enabled and dac,
        initial_volume: value >>> 4,
        envelope_add: bit?(value, 3),
        envelope_period: value &&& 7
    }

    Map.put(psg, channel, ch)
  end

  defp write_frequency_low(psg, channel, value) do
    ch = Map.fetch!(psg, channel)
    Map.put(psg, channel, %{ch | frequency: (ch.frequency &&& 0x700) ||| value})
  end

  defp write_frequency_high(psg, channel, value) do
    ch = Map.fetch!(psg, channel)
    frequency = (ch.frequency &&& 0xFF) ||| (value &&& 7) <<< 8
    ch = update_length_enable(%{ch | frequency: frequency}, value, psg.sequencer_step)
    ch = if bit?(value, 7), do: trigger_pulse(ch, channel == :ch1, psg.sequencer_step), else: ch
    Map.put(psg, channel, ch)
  end

  defp update_length_enable(ch, value, sequencer_step) do
    enable? = bit?(value, 6)
    extra_clock? = enable? and not ch.length_enable and sequencer_step not in [0, 2, 4, 6]
    ch = %{ch | length_enable: enable?}
    if extra_clock?, do: clock_length(ch), else: ch
  end

  defp trigger_pulse(ch, sweep?, sequencer_step) do
    ch = %{
      ch
      | enabled: ch.dac,
        length: trigger_length(ch.length, 64, ch.length_enable, sequencer_step),
        timer: pulse_period(ch.frequency),
        volume: ch.initial_volume,
        envelope_timer: envelope_reload(ch.envelope_period)
    }

    if sweep? do
      ch = %{
        ch
        | sweep_shadow: ch.frequency,
          sweep_timer: max(ch.sweep_period, 1),
          sweep_enabled: ch.sweep_period != 0
      }

      if ch.sweep_shift != 0 and sweep_frequency(ch) > 0x7FF,
        do: %{ch | enabled: false},
        else: ch
    else
      ch
    end
  end

  defp trigger_wave(ch, wave_ram, sequencer_step) do
    position = ch.bank * 32

    %{
      ch
      | enabled: ch.dac,
        length: trigger_length(ch.length, 256, ch.length_enable, sequencer_step),
        timer: wave_period(ch.frequency),
        position: position,
        sample_buffer: wave_sample(wave_ram, position)
    }
  end

  defp trigger_noise(ch, sequencer_step) do
    %{
      ch
      | enabled: ch.dac,
        length: trigger_length(ch.length, 64, ch.length_enable, sequencer_step),
        timer: noise_period(ch),
        volume: ch.initial_volume,
        envelope_timer: envelope_reload(ch.envelope_period),
        lfsr: 0x7FFF
    }
  end

  defp trigger_length(0, maximum, true, sequencer_step)
       when sequencer_step not in [0, 2, 4, 6],
       do: maximum - 1

  defp trigger_length(0, maximum, _enabled, _sequencer_step), do: maximum
  defp trigger_length(length, _maximum, _enabled, _sequencer_step), do: length

  defp pulse_output(%{enabled: false}), do: 0
  defp pulse_output(%{dac: false}), do: 0

  defp pulse_output(ch) do
    bit = elem(elem(@duty_rows, ch.duty), ch.duty_pos)
    elem(@dac_levels, bit * ch.volume)
  end

  defp wave_output(%{enabled: false}), do: 0
  defp wave_output(%{dac: false}), do: 0

  defp wave_output(ch) do
    sample =
      cond do
        ch.force_volume -> div(ch.sample_buffer * 3, 4)
        ch.level == 0 -> 0
        true -> ch.sample_buffer >>> (ch.level - 1)
      end

    elem(@dac_levels, sample)
  end

  defp noise_output(%{enabled: false}), do: 0
  defp noise_output(%{dac: false}), do: 0
  defp noise_output(ch), do: elem(@dac_levels, (bxor(ch.lfsr, 1) &&& 1) * ch.volume)

  defp routed_sum(outputs, routes) do
    if((routes &&& 1) != 0, do: elem(outputs, 0), else: 0) +
      if((routes &&& 2) != 0, do: elem(outputs, 1), else: 0) +
      if((routes &&& 4) != 0, do: elem(outputs, 2), else: 0) +
      if((routes &&& 8) != 0, do: elem(outputs, 3), else: 0)
  end

  defp wave_position(%{dimension: true, position: position}, steps), do: rem(position + steps, 64)

  defp wave_position(%{dimension: false, bank: bank, position: position}, steps),
    do: bank * 32 + rem(position - bank * 32 + steps, 32)

  defp wave_sample(wave_ram, position) do
    byte = :binary.at(wave_ram, position >>> 1)
    if bit?(position, 0), do: byte &&& 0x0F, else: byte >>> 4
  end

  defp sweep_frequency(ch) do
    delta = ch.sweep_shadow >>> ch.sweep_shift
    if ch.sweep_negate, do: ch.sweep_shadow - delta, else: ch.sweep_shadow + delta
  end

  defp pulse_period(frequency), do: (2048 - frequency) * 16
  defp wave_period(frequency), do: (2048 - frequency) * 8
  defp noise_period(ch), do: elem(@noise_divisors, ch.divisor) <<< ch.shift
  defp envelope_reload(0), do: 8
  defp envelope_reload(period), do: period
  defp channel_status(%{enabled: true}, bit), do: 1 <<< bit
  defp channel_status(_channel, _bit), do: 0

  defp power_off(psg) do
    %{
      psg
      | master: false,
        soundcnt_l: 0,
        ch1: @pulse,
        ch2: @pulse,
        ch3: @wave,
        ch4: @noise
    }
  end

  defp put_byte(binary, offset, value) do
    <<prefix::binary-size(^offset), _old, suffix::binary>> = binary
    prefix <> <<value>> <> suffix
  end

  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
