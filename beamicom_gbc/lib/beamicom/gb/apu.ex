defmodule Beamicom.GB.APU.Pulse do
  @moduledoc false
  defstruct enabled: false,
            dac: false,
            length: 0,
            length_enable: false,
            duty: 0,
            duty_pos: 0,
            frequency: 0,
            timer: 4,
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
end

defmodule Beamicom.GB.APU.Wave do
  @moduledoc false
  defstruct enabled: false,
            dac: false,
            length: 0,
            length_enable: false,
            level: 0,
            frequency: 0,
            timer: 2,
            position: 0,
            sample_buffer: 0
end

defmodule Beamicom.GB.APU.Noise do
  @moduledoc false
  defstruct enabled: false,
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
            timer: 8,
            lfsr: 0x7FFF
end

defmodule Beamicom.GB.APU do
  @moduledoc """
  Pure four-channel DMG/CGB audio processing unit.

  Oscillators run in base 4,194,304 Hz dots and output deterministic interleaved
  signed-16-bit little-endian stereo PCM at 44.1 kHz. Advancement jumps between
  sample and 512 Hz frame-sequencer boundaries; pulse and wave periods are
  advanced arithmetically rather than one dot at a time.

  The digital channel behavior, length, envelope, sweep, routing, and volume
  units are modeled. Analog high-pass filtering, capacitor behavior, DAC pop,
  zombie envelope quirks, and active wave-RAM access/corruption differences
  between hardware revisions are not yet modeled. CGB PCM amplitude registers
  FF76 and FF77 are deferred until the model exposes its internal mixer levels.
  """

  import Bitwise

  @compile {:no_warn_undefined, Beamicom.GB.Nx.APUBlockRenderer}

  @clock_rate 4_194_304
  @sample_rate 44_100
  @sequencer_period 8_192
  @silence <<0::little-signed-16, 0::little-signed-16>>
  @blank_wave :binary.copy(<<0>>, 16)
  @zero_registers List.duplicate(0, 23) |> List.to_tuple()

  @read_masks {0x80, 0x3F, 0x00, 0xFF, 0xBF, 0xFF, 0x3F, 0x00, 0xFF, 0xBF, 0x7F, 0xFF, 0x9F, 0xFF,
               0xBF, 0xFF, 0xFF, 0x00, 0x00, 0xBF, 0x00, 0x00}

  @duty_rows {
    {0, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 1, 1, 1},
    {0, 1, 1, 1, 1, 1, 1, 0}
  }

  @dac_levels {15, 13, 11, 9, 7, 5, 3, 1, -1, -3, -5, -7, -9, -11, -13, -15}
  @noise_divisors {8, 16, 32, 48, 64, 80, 96, 112}

  alias __MODULE__.{Noise, Pulse, Wave}

  defstruct model: :dmg,
            master: false,
            registers: @zero_registers,
            wave_ram: @blank_wave,
            ch1: %Pulse{},
            ch2: %Pulse{},
            ch3: %Wave{},
            ch4: %Noise{},
            sequencer_phase: 0,
            sequencer_step: 0,
            sample_phase: 0,
            pending_dots: 0,
            samples: [],
            sample_count: 0,
            render_events: [],
            render_dots: 0,
            render_triggers: {0, 0, 0, 0},
            renderer: :native,
            renderer_state: nil

  @type t :: %__MODULE__{}

  @doc "Creates a powered-off APU. Wave RAM remains accessible while powered off."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    model = Keyword.get(opts, :model, :dmg)
    unless model in [:dmg, :cgb], do: raise(ArgumentError, "model must be :dmg or :cgb")

    renderer =
      case Application.get_env(:beamicom_gbc, :apu_renderer, :native) do
        :nx_block -> Beamicom.GB.Nx.APUBlockRenderer
        configured -> configured
      end

    apu = %__MODULE__{model: model, renderer: renderer}
    %{apu | renderer_state: prepare_renderer(renderer, apu)}
  end

  @doc "Selects inline native mixing or an optional block renderer."
  @spec set_renderer(t(), :native | :nx_block | module()) :: t()
  def set_renderer(apu, :native),
    do: %{
      apu
      | renderer: :native,
        renderer_state: nil,
        samples: [],
        sample_count: 0,
        render_events: [],
        render_dots: 0
    }

  def set_renderer(apu, :nx_block),
    do: set_renderer(apu, Beamicom.GB.Nx.APUBlockRenderer)

  def set_renderer(apu, renderer) when is_atom(renderer) do
    configured = %{
      apu
      | renderer: renderer,
        samples: [],
        sample_count: 0,
        render_events: [],
        render_dots: 0
    }

    %{configured | renderer_state: prepare_renderer(renderer, configured)}
  end

  defp prepare_renderer(:native, _apu), do: nil

  defp prepare_renderer(renderer, apu) do
    unless Code.ensure_loaded?(renderer) and function_exported?(renderer, :prepare, 1),
      do: raise("invalid Game Boy APU renderer: #{inspect(renderer)}")

    apply(renderer, :prepare, [apu])
  end

  @doc "Creates the stable, documented portion of the post-boot audio state."
  @spec post_boot(keyword()) :: t()
  def post_boot(opts \\ []) do
    new(opts)
    |> write(0xFF26, 0x80)
    |> write(0xFF10, 0x80)
    |> write(0xFF11, 0x80)
    |> write(0xFF12, 0xF3)
    |> write(0xFF13, 0xFF)
    |> write(0xFF14, 0x87)
    |> write(0xFF16, 0x00)
    |> write(0xFF17, 0x00)
    |> write(0xFF19, 0x00)
    |> write(0xFF1A, 0x00)
    |> write(0xFF1C, 0x00)
    |> write(0xFF1E, 0x00)
    |> write(0xFF20, 0x00)
    |> write(0xFF21, 0x00)
    |> write(0xFF22, 0x00)
    |> write(0xFF23, 0x00)
    |> write(0xFF24, 0x77)
    |> write(0xFF25, 0xF3)
  end

  @doc "Reads an audio register or wave RAM byte."
  @spec read(t(), 0xFF10..0xFF3F) :: byte()
  def read(%__MODULE__{} = apu, address) when address in 0xFF10..0xFF25 do
    index = address - 0xFF10
    elem(apu.registers, index) ||| elem(@read_masks, index)
  end

  def read(%__MODULE__{master: false}, 0xFF26), do: 0x70

  def read(%__MODULE__{ch1: ch1, ch2: ch2, ch3: ch3, ch4: ch4}, 0xFF26) do
    0xF0 ||| channel_status(ch1, 1) ||| channel_status(ch2, 2) |||
      channel_status(ch3, 4) ||| channel_status(ch4, 8)
  end

  def read(%__MODULE__{}, address) when address in 0xFF27..0xFF2F, do: 0xFF

  def read(%__MODULE__{wave_ram: wave}, address) when address in 0xFF30..0xFF3F,
    do: :binary.at(wave, address - 0xFF30)

  @doc "Writes an audio register and returns the updated pure state."
  @spec write(t(), 0xFF10..0xFF3F, byte()) :: t()
  def write(%__MODULE__{} = apu, address, value)
      when address in 0xFF10..0xFF3F and value in 0..0xFF do
    updated = write_immediate(apu, address, value)

    if event_renderer?(apu.renderer), do: record_trigger(updated, address, value), else: updated
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF26, value)
       when value in 0..0xFF and (value &&& 0x80) == 0,
       do: power_off(apu)

  defp write_immediate(%__MODULE__{master: true} = apu, 0xFF26, value) when value in 0..0xFF,
    do: apu

  defp write_immediate(%__MODULE__{} = apu, 0xFF26, value) when value in 0..0xFF,
    do: %{apu | master: true}

  defp write_immediate(%__MODULE__{wave_ram: wave} = apu, address, value)
       when address in 0xFF30..0xFF3F and value in 0..0xFF,
       do: %{apu | wave_ram: put_byte(wave, address - 0xFF30, value)}

  defp write_immediate(%__MODULE__{master: false, model: :dmg} = apu, address, value)
       when address in [0xFF11, 0xFF16, 0xFF1B, 0xFF20] and value in 0..0xFF,
       do: write_powered_off_length(apu, address, value)

  defp write_immediate(%__MODULE__{master: false} = apu, address, value)
       when address in 0xFF10..0xFF2F and value in 0..0xFF,
       do: apu

  defp write_immediate(%__MODULE__{} = apu, 0xFF10, value),
    do:
      apu
      |> put_register(0, value &&& 0x7F)
      |> update_sweep(value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF11, value) do
    ch = %{apu.ch1 | duty: value >>> 6, length: 64 - (value &&& 0x3F)}
    %{put_register(apu, 1, value) | ch1: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF12, value),
    do: write_pulse_envelope(apu, :ch1, 2, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF13, value),
    do: write_pulse_low(apu, :ch1, 3, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF14, value),
    do: write_pulse_high(apu, :ch1, 4, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF15, _value), do: apu

  defp write_immediate(%__MODULE__{} = apu, 0xFF16, value) do
    ch = %{apu.ch2 | duty: value >>> 6, length: 64 - (value &&& 0x3F)}
    %{put_register(apu, 6, value) | ch2: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF17, value),
    do: write_pulse_envelope(apu, :ch2, 7, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF18, value),
    do: write_pulse_low(apu, :ch2, 8, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF19, value),
    do: write_pulse_high(apu, :ch2, 9, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF1A, value) do
    dac = (value &&& 0x80) != 0
    ch = %{apu.ch3 | dac: dac, enabled: apu.ch3.enabled and dac}
    %{put_register(apu, 10, value &&& 0x80) | ch3: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF1B, value) do
    %{put_register(apu, 11, value) | ch3: %{apu.ch3 | length: 256 - value}}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF1C, value) do
    %{put_register(apu, 12, value &&& 0x60) | ch3: %{apu.ch3 | level: value >>> 5 &&& 3}}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF1D, value) do
    frequency = (apu.ch3.frequency &&& 0x700) ||| value
    %{put_register(apu, 13, value) | ch3: %{apu.ch3 | frequency: frequency}}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF1E, value) do
    frequency = (apu.ch3.frequency &&& 0xFF) ||| (value &&& 7) <<< 8
    ch = update_length_enable(%{apu.ch3 | frequency: frequency}, value, apu.sequencer_step)

    ch =
      if (value &&& 0x80) == 0,
        do: ch,
        else: trigger_wave(ch, apu.sequencer_step)

    %{put_register(apu, 14, value &&& 0x47) | ch3: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF1F, _value), do: apu

  defp write_immediate(%__MODULE__{} = apu, 0xFF20, value) do
    %{put_register(apu, 16, value) | ch4: %{apu.ch4 | length: 64 - (value &&& 0x3F)}}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF21, value), do: write_noise_envelope(apu, value)

  defp write_immediate(%__MODULE__{} = apu, 0xFF22, value) do
    ch = %{
      apu.ch4
      | shift: value >>> 4,
        width7: (value &&& 8) != 0,
        divisor: value &&& 7
    }

    %{put_register(apu, 18, value) | ch4: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF23, value) do
    ch = update_length_enable(apu.ch4, value, apu.sequencer_step)

    ch =
      if (value &&& 0x80) == 0,
        do: ch,
        else: trigger_noise(ch, apu.sequencer_step)

    %{put_register(apu, 19, value &&& 0x40) | ch4: ch}
  end

  defp write_immediate(%__MODULE__{} = apu, 0xFF24, value), do: put_register(apu, 20, value)
  defp write_immediate(%__MODULE__{} = apu, 0xFF25, value), do: put_register(apu, 21, value)

  defp write_immediate(%__MODULE__{} = apu, address, _value) when address in 0xFF27..0xFF2F,
    do: apu

  @doc false
  @spec defer_tick(t(), non_neg_integer()) :: t()
  def defer_tick(%__MODULE__{} = apu, 0), do: apu

  def defer_tick(%__MODULE__{pending_dots: pending} = apu, dots) when dots > 0,
    do: %{apu | pending_dots: pending + dots}

  @doc "Applies deferred dots and accumulates exact-rate stereo PCM."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{pending_dots: 0} = apu), do: apu

  def flush(%__MODULE__{pending_dots: dots} = apu),
    do: apu |> Map.put(:pending_dots, 0) |> tick_immediate(dots)

  @doc "Advances base hardware dots immediately and accumulates exact-rate stereo PCM."
  @spec tick(t(), non_neg_integer()) :: t()
  def tick(%__MODULE__{} = apu, dots) when dots >= 0,
    do: apu |> flush() |> tick_immediate(dots)

  defp tick_immediate(%__MODULE__{} = apu, 0), do: apu

  defp tick_immediate(%__MODULE__{master: false} = apu, dots) when dots > 0 do
    if event_renderer?(apu.renderer) do
      advance_events(apu, dots)
    else
      total = apu.sample_phase + dots * @sample_rate
      count = div(total, @clock_rate)
      phase = total - count * @clock_rate
      seq_total = apu.sequencer_phase + dots
      seq_ticks = div(seq_total, @sequencer_period)
      seq_phase = seq_total - seq_ticks * @sequencer_period

      %{
        apu
        | sample_phase: phase,
          samples: append_silence(apu, count),
          sample_count: apu.sample_count + count,
          sequencer_phase: seq_phase,
          sequencer_step: apu.sequencer_step + seq_ticks &&& 7
      }
    end
  end

  defp tick_immediate(%__MODULE__{} = apu, dots) when dots > 0 do
    if event_renderer?(apu.renderer), do: advance_events(apu, dots), else: advance(apu, dots)
  end

  @doc "Clocks one DIV-APU edge, used for the FF04 reset falling-edge quirk."
  @spec clock_frame_sequencer(t()) :: t()
  def clock_frame_sequencer(%__MODULE__{master: false} = apu),
    do: %{apu | sequencer_step: apu.sequencer_step + 1 &&& 7}

  def clock_frame_sequencer(%__MODULE__{} = apu) do
    apu = clock_sequencer_units(apu, apu.sequencer_step)
    %{apu | sequencer_step: apu.sequencer_step + 1 &&& 7}
  end

  @doc "Resynchronizes DIV-APU after DIV is cleared, optionally clocking its falling edge."
  @spec reset_divider(t(), boolean()) :: t()
  def reset_divider(%__MODULE__{} = apu, falling_edge?) do
    apu = if falling_edge?, do: clock_frame_sequencer(apu), else: apu
    %{apu | sequencer_phase: 0}
  end

  @doc "Returns and clears accumulated PCM without changing synthesis state."
  @spec take_samples(t()) :: {non_neg_integer(), binary(), t()}
  def take_samples(%__MODULE__{} = apu) do
    %__MODULE__{samples: samples, sample_count: count} = apu = flush(apu)

    {rendered_count, pcm, renderer_state} =
      cond do
        apu.renderer == :native ->
          {count, samples |> :lists.reverse() |> IO.iodata_to_binary(), nil}

        event_renderer?(apu.renderer) ->
          apply(apu.renderer, :render_events, [
            apu.renderer_state,
            :lists.reverse(apu.render_events),
            apu.render_dots,
            count
          ])

        true ->
          {pcm, state} =
            apply(apu.renderer, :render, [apu.renderer_state, :lists.reverse(samples), count])

          {count, pcm, state}
      end

    unless rendered_count == count,
      do: raise("Game Boy APU renderer sample count mismatch: #{rendered_count} != #{count}")

    {count, pcm,
     %{
       apu
       | samples: [],
         sample_count: 0,
         render_events: [],
         render_dots: 0,
         renderer_state: renderer_state
     }}
  end

  defp advance(apu, 0), do: apu

  defp advance(apu, dots) do
    to_sample = div(@clock_rate - apu.sample_phase + @sample_rate - 1, @sample_rate)
    to_sequence = @sequencer_period - apu.sequencer_phase
    distance = min(dots, min(to_sample, to_sequence))
    apu = advance_channels(apu, distance)
    sample_phase = apu.sample_phase + distance * @sample_rate
    sequence_phase = apu.sequencer_phase + distance
    apu = %{apu | sample_phase: sample_phase, sequencer_phase: sequence_phase}

    apu =
      if sample_phase >= @clock_rate do
        sample = if apu.renderer == :native, do: mix_sample(apu), else: sample_levels(apu)

        %{
          apu
          | sample_phase: sample_phase - @clock_rate,
            samples: [sample | apu.samples],
            sample_count: apu.sample_count + 1
        }
      else
        apu
      end

    apu =
      if sequence_phase == @sequencer_period do
        apu |> Map.put(:sequencer_phase, 0) |> clock_frame_sequencer()
      else
        apu
      end

    advance(apu, dots - distance)
  end

  defp advance_events(apu, 0), do: apu

  defp advance_events(apu, dots) do
    distance = min(dots, @sequencer_period - apu.sequencer_phase)
    apu = append_render_segment(apu, distance)
    sample_total = apu.sample_phase + distance * @sample_rate
    emitted = div(sample_total, @clock_rate)
    sequence_phase = apu.sequencer_phase + distance

    apu = %{
      apu
      | sample_phase: sample_total - emitted * @clock_rate,
        sample_count: apu.sample_count + emitted,
        sequencer_phase: sequence_phase
    }

    apu =
      if sequence_phase == @sequencer_period do
        apu |> Map.put(:sequencer_phase, 0) |> clock_frame_sequencer()
      else
        apu
      end

    advance_events(apu, dots - distance)
  end

  defp advance_channels(apu, dots) do
    %{
      apu
      | ch1: advance_pulse(apu.ch1, dots),
        ch2: advance_pulse(apu.ch2, dots),
        ch3: advance_wave(apu.ch3, apu.wave_ram, dots),
        ch4: advance_noise(apu.ch4, dots)
    }
  end

  defp advance_pulse(%Pulse{enabled: false} = ch, _dots), do: ch

  defp advance_pulse(%Pulse{} = ch, dots) when dots < ch.timer,
    do: %{ch | timer: ch.timer - dots}

  defp advance_pulse(%Pulse{} = ch, dots) do
    period = pulse_period(ch.frequency)
    after_first = dots - ch.timer
    steps = 1 + div(after_first, period)
    remainder = after_first - (steps - 1) * period
    timer = if remainder == 0, do: period, else: period - remainder
    %{ch | timer: timer, duty_pos: ch.duty_pos + steps &&& 7}
  end

  defp advance_wave(%Wave{enabled: false} = ch, _wave, _dots), do: ch

  defp advance_wave(%Wave{} = ch, _wave, dots) when dots < ch.timer,
    do: %{ch | timer: ch.timer - dots}

  defp advance_wave(%Wave{} = ch, wave, dots) do
    period = wave_period(ch.frequency)
    after_first = dots - ch.timer
    steps = 1 + div(after_first, period)
    remainder = after_first - (steps - 1) * period
    timer = if remainder == 0, do: period, else: period - remainder
    position = ch.position + steps &&& 31
    byte = :binary.at(wave, position >>> 1)
    sample = if (position &&& 1) == 0, do: byte >>> 4, else: byte &&& 0x0F
    %{ch | timer: timer, position: position, sample_buffer: sample}
  end

  defp advance_noise(%Noise{enabled: false} = ch, _dots), do: ch
  defp advance_noise(%Noise{shift: shift} = ch, _dots) when shift >= 14, do: ch
  defp advance_noise(%Noise{} = ch, dots) when dots < ch.timer, do: %{ch | timer: ch.timer - dots}

  defp advance_noise(%Noise{} = ch, dots) do
    period = noise_period(ch)
    after_first = dots - ch.timer
    steps = 1 + div(after_first, period)
    remainder = rem(after_first, period)
    timer = if remainder == 0, do: period, else: period - remainder
    %{ch | timer: timer, lfsr: advance_lfsr(ch.lfsr, steps, ch.width7)}
  end

  defp advance_lfsr(lfsr, 0, _width7), do: lfsr

  defp advance_lfsr(lfsr, steps, width7) do
    feedback = bxor(lfsr, lfsr >>> 1) &&& 1
    lfsr = lfsr >>> 1 ||| feedback <<< 14
    lfsr = if width7, do: (lfsr &&& bxor(0x40, 0x7FFF)) ||| feedback <<< 6, else: lfsr
    advance_lfsr(lfsr, steps - 1, width7)
  end

  defp clock_sequencer_units(apu, step) do
    apu = if step in [0, 2, 4, 6], do: clock_lengths(apu), else: apu
    apu = if step in [2, 6], do: clock_sweep(apu), else: apu
    if step == 7, do: clock_envelopes(apu), else: apu
  end

  defp clock_lengths(apu) do
    %{
      apu
      | ch1: clock_length(apu.ch1),
        ch2: clock_length(apu.ch2),
        ch3: clock_length(apu.ch3),
        ch4: clock_length(apu.ch4)
    }
  end

  defp clock_length(%{length_enable: true, length: 1} = ch),
    do: %{ch | length: 0, enabled: false}

  defp clock_length(%{length_enable: true, length: length} = ch) when length > 1,
    do: %{ch | length: length - 1}

  defp clock_length(ch), do: ch

  defp clock_envelopes(apu),
    do: %{
      apu
      | ch1: clock_envelope(apu.ch1),
        ch2: clock_envelope(apu.ch2),
        ch4: clock_envelope(apu.ch4)
    }

  defp clock_envelope(%{enabled: false} = ch), do: ch
  defp clock_envelope(%{envelope_period: 0} = ch), do: ch

  defp clock_envelope(%{envelope_timer: timer} = ch) when timer > 1,
    do: %{ch | envelope_timer: timer - 1}

  defp clock_envelope(ch) do
    next = if ch.envelope_add, do: ch.volume + 1, else: ch.volume - 1
    volume = if next in 0..15, do: next, else: ch.volume
    %{ch | volume: volume, envelope_timer: envelope_reload(ch.envelope_period)}
  end

  defp clock_sweep(%{ch1: %Pulse{sweep_enabled: false}} = apu), do: apu

  defp clock_sweep(%{ch1: %Pulse{sweep_timer: timer} = ch} = apu) when timer > 1,
    do: %{apu | ch1: %{ch | sweep_timer: timer - 1}}

  defp clock_sweep(%{ch1: %Pulse{sweep_period: 0} = ch} = apu),
    do: %{apu | ch1: %{ch | sweep_timer: 8}}

  defp clock_sweep(%{ch1: ch} = apu) do
    ch = %{ch | sweep_timer: ch.sweep_period}
    apply_sweep(apu, ch, sweep_frequency(ch))
  end

  defp apply_sweep(apu, ch, frequency) when frequency > 0x7FF,
    do: %{apu | ch1: %{ch | enabled: false}}

  defp apply_sweep(apu, %Pulse{sweep_shift: 0} = ch, _frequency), do: %{apu | ch1: ch}

  defp apply_sweep(apu, ch, frequency) do
    ch = %{ch | frequency: frequency, sweep_shadow: frequency}
    ch = disable_on_sweep_overflow(ch, sweep_frequency(ch))
    high = (elem(apu.registers, 4) &&& 0x40) ||| (frequency >>> 8 &&& 7)

    registers = apu.registers |> put_elem(3, frequency &&& 0xFF) |> put_elem(4, high)
    %{apu | ch1: ch, registers: registers}
  end

  defp disable_on_sweep_overflow(ch, frequency) when frequency > 0x7FF,
    do: %{ch | enabled: false}

  defp disable_on_sweep_overflow(ch, _frequency), do: ch

  defp channel_status(%{enabled: true}, bit), do: bit
  defp channel_status(_channel, _bit), do: 0

  defp mix_sample(apu) do
    outputs =
      {pulse_output(apu.ch1), pulse_output(apu.ch2), wave_output(apu.ch3, apu.wave_ram),
       noise_output(apu.ch4)}

    nr50 = elem(apu.registers, 20)
    nr51 = elem(apu.registers, 21)
    right = routed_sum(outputs, nr51 &&& 0x0F) * ((nr50 &&& 7) + 1) * 64
    left = routed_sum(outputs, nr51 >>> 4) * ((nr50 >>> 4 &&& 7) + 1) * 64
    <<clamp16(left)::little-signed-16, clamp16(right)::little-signed-16>>
  end

  defp sample_levels(apu) do
    <<pulse_output(apu.ch1)::little-signed-16, pulse_output(apu.ch2)::little-signed-16,
      wave_output(apu.ch3, apu.wave_ram)::little-signed-16,
      noise_output(apu.ch4)::little-signed-16, elem(apu.registers, 20)::little-signed-16,
      elem(apu.registers, 21)::little-signed-16>>
  end

  defp append_silence(apu, 0), do: apu.samples

  defp append_silence(%__MODULE__{renderer: :native} = apu, count),
    do: [:binary.copy(@silence, count) | apu.samples]

  defp append_silence(apu, count), do: [:binary.copy(<<0::size(6 * 16)>>, count) | apu.samples]

  defp event_renderer?(:native), do: false

  defp event_renderer?(renderer),
    do: function_exported?(renderer, :event_driven?, 0) and apply(renderer, :event_driven?, [])

  defp append_render_segment(apu, dots) do
    %{
      apu
      | render_events: [render_segment(apu, dots) | apu.render_events],
        render_dots: apu.render_dots + dots
    }
  end

  defp render_segment(apu, dots) do
    {t1, t2, t3, t4} = apu.render_triggers
    nr50 = elem(apu.registers, 20)
    nr51 = elem(apu.registers, 21)
    p1 = apu.ch1
    p2 = apu.ch2
    wave = apu.ch3
    noise = apu.ch4

    [
      dots,
      bool(apu.master),
      nr50,
      nr51,
      bool(p1.enabled),
      bool(p1.dac),
      p1.duty,
      p1.frequency,
      p1.volume,
      t1,
      bool(p2.enabled),
      bool(p2.dac),
      p2.duty,
      p2.frequency,
      p2.volume,
      t2,
      bool(wave.enabled),
      bool(wave.dac),
      wave.level,
      wave.frequency,
      t3
      | :binary.bin_to_list(apu.wave_ram) ++
          [
            bool(noise.enabled),
            bool(noise.dac),
            noise.volume,
            noise.shift,
            bool(noise.width7),
            noise.divisor,
            t4
          ]
    ]
  end

  defp record_trigger(apu, address, value) when (value &&& 0x80) != 0 do
    index =
      case address do
        0xFF14 -> 0
        0xFF19 -> 1
        0xFF1E -> 2
        0xFF23 -> 3
        _address -> nil
      end

    if index == nil do
      apu
    else
      triggers = apu.render_triggers
      %{apu | render_triggers: put_elem(triggers, index, elem(triggers, index) + 1)}
    end
  end

  defp record_trigger(apu, _address, _value), do: apu
  defp bool(true), do: 1
  defp bool(false), do: 0

  defp routed_sum(outputs, routes) do
    if((routes &&& 1) != 0, do: elem(outputs, 0), else: 0) +
      if((routes &&& 2) != 0, do: elem(outputs, 1), else: 0) +
      if((routes &&& 4) != 0, do: elem(outputs, 2), else: 0) +
      if((routes &&& 8) != 0, do: elem(outputs, 3), else: 0)
  end

  defp pulse_output(%Pulse{enabled: false}), do: 0
  defp pulse_output(%Pulse{dac: false}), do: 0

  defp pulse_output(ch) do
    bit = elem(elem(@duty_rows, ch.duty), ch.duty_pos)
    elem(@dac_levels, bit * ch.volume)
  end

  defp wave_output(%Wave{enabled: false}, _wave), do: 0
  defp wave_output(%Wave{dac: false}, _wave), do: 0
  defp wave_output(%Wave{level: 0}, _wave), do: 15

  defp wave_output(ch, _wave) do
    shift = ch.level - 1
    elem(@dac_levels, ch.sample_buffer >>> shift)
  end

  defp noise_output(%Noise{enabled: false}), do: 0
  defp noise_output(%Noise{dac: false}), do: 0
  defp noise_output(ch), do: elem(@dac_levels, (bxor(ch.lfsr, 1) &&& 1) * ch.volume)

  defp clamp16(sample) when sample < -32_768, do: -32_768
  defp clamp16(sample) when sample > 32_767, do: 32_767
  defp clamp16(sample), do: sample

  defp write_pulse_envelope(apu, channel, index, value) do
    ch = Map.fetch!(apu, channel)
    dac = (value &&& 0xF8) != 0

    ch = %{
      ch
      | dac: dac,
        enabled: ch.enabled and dac,
        initial_volume: value >>> 4,
        envelope_add: (value &&& 8) != 0,
        envelope_period: value &&& 7
    }

    apu |> put_register(index, value) |> Map.put(channel, ch)
  end

  defp write_noise_envelope(apu, value) do
    dac = (value &&& 0xF8) != 0

    ch = %{
      apu.ch4
      | dac: dac,
        enabled: apu.ch4.enabled and dac,
        initial_volume: value >>> 4,
        envelope_add: (value &&& 8) != 0,
        envelope_period: value &&& 7
    }

    %{put_register(apu, 17, value) | ch4: ch}
  end

  defp write_pulse_low(apu, channel, index, value) do
    ch = Map.fetch!(apu, channel)
    ch = %{ch | frequency: (ch.frequency &&& 0x700) ||| value}
    apu |> put_register(index, value) |> Map.put(channel, ch)
  end

  defp write_pulse_high(apu, channel, index, value) do
    ch = Map.fetch!(apu, channel)
    frequency = (ch.frequency &&& 0xFF) ||| (value &&& 7) <<< 8
    ch = update_length_enable(%{ch | frequency: frequency}, value, apu.sequencer_step)

    ch =
      if (value &&& 0x80) == 0,
        do: ch,
        else: trigger_pulse(ch, channel == :ch1, apu.sequencer_step)

    apu |> put_register(index, value &&& 0x47) |> Map.put(channel, ch)
  end

  defp update_length_enable(ch, value, sequencer_step) do
    enable = (value &&& 0x40) != 0
    extra_clock? = enable and not ch.length_enable and not length_step?(sequencer_step)
    ch = %{ch | length_enable: enable}
    if extra_clock?, do: clock_length(ch), else: ch
  end

  defp trigger_length(0, maximum, true, sequencer_step) do
    if length_step?(sequencer_step), do: maximum, else: maximum - 1
  end

  defp trigger_length(0, maximum, _enabled, _sequencer_step), do: maximum
  defp trigger_length(length, _maximum, _enabled, _sequencer_step), do: length

  defp length_step?(step), do: step in [0, 2, 4, 6]

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
          sweep_timer: envelope_reload(ch.sweep_period),
          sweep_enabled: ch.sweep_period != 0 or ch.sweep_shift != 0
      }

      if ch.sweep_shift != 0 and sweep_frequency(ch) > 0x7FF,
        do: %{ch | enabled: false},
        else: ch
    else
      ch
    end
  end

  defp trigger_wave(ch, sequencer_step),
    do: %{
      ch
      | enabled: ch.dac,
        length: trigger_length(ch.length, 256, ch.length_enable, sequencer_step),
        timer: wave_period(ch.frequency),
        position: 0
    }

  defp trigger_noise(ch, sequencer_step),
    do: %{
      ch
      | enabled: ch.dac,
        length: trigger_length(ch.length, 64, ch.length_enable, sequencer_step),
        timer: noise_period(ch),
        volume: ch.initial_volume,
        envelope_timer: envelope_reload(ch.envelope_period),
        lfsr: 0x7FFF
    }

  defp update_sweep(apu, value) do
    ch = %{
      apu.ch1
      | sweep_period: value >>> 4 &&& 7,
        sweep_negate: (value &&& 8) != 0,
        sweep_shift: value &&& 7
    }

    %{apu | ch1: ch}
  end

  defp envelope_reload(0), do: 8
  defp envelope_reload(period), do: period

  defp sweep_frequency(ch) do
    delta = ch.sweep_shadow >>> ch.sweep_shift
    if ch.sweep_negate, do: ch.sweep_shadow - delta, else: ch.sweep_shadow + delta
  end

  defp pulse_period(frequency), do: (2048 - frequency) * 4
  defp wave_period(frequency), do: (2048 - frequency) * 2
  defp noise_period(ch), do: elem(@noise_divisors, ch.divisor) <<< ch.shift

  defp power_off(apu) do
    %{
      apu
      | master: false,
        registers: @zero_registers,
        ch1: %Pulse{},
        ch2: %Pulse{},
        ch3: %Wave{},
        ch4: %Noise{}
    }
  end

  defp write_powered_off_length(apu, 0xFF11, value),
    do: %{apu | ch1: %{apu.ch1 | length: 64 - (value &&& 0x3F)}}

  defp write_powered_off_length(apu, 0xFF16, value),
    do: %{apu | ch2: %{apu.ch2 | length: 64 - (value &&& 0x3F)}}

  defp write_powered_off_length(apu, 0xFF1B, value),
    do: %{apu | ch3: %{apu.ch3 | length: 256 - value}}

  defp write_powered_off_length(apu, 0xFF20, value),
    do: %{apu | ch4: %{apu.ch4 | length: 64 - (value &&& 0x3F)}}

  defp put_register(%__MODULE__{registers: registers} = apu, index, value),
    do: %{apu | registers: put_elem(registers, index, value &&& 0xFF)}

  defp put_byte(binary, offset, value) do
    <<prefix::binary-size(^offset), _old, suffix::binary>> = binary
    prefix <> <<value>> <> suffix
  end
end
