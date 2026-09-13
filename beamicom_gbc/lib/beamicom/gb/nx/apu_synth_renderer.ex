if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.GB.Nx.APUSynthRenderer do
    @moduledoc """
    Event-block EXLA synthesizer for both Game Boy pulse channels, wave, and noise.

    The core supplies control-state epochs bounded by register and frame-sequencer
    changes. Oscillator timers, phase, LFSR state, stereo routing, and PCM remain
    resident in this renderer across frames.
    """

    import Nx.Defn
    @behaviour Beamicom.GB.APURenderer

    @capacity 128
    @width 44
    # The first emitted video frame can include several LCD-off setup frames of
    # audio. A fixed 8192-frame result covers that boot interval without changing
    # the compiled shape; steady-state calls use about 739 entries.
    @steady_samples 1024
    @boot_samples 8192
    @segment_samples 128
    @clock_rate 4_194_304
    @sample_rate 44_100

    @duty [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      0,
      0,
      0,
      0,
      1,
      1,
      1,
      0,
      1,
      1,
      1,
      1,
      1,
      1,
      0
    ]
    @dac [15, 13, 11, 9, 7, 5, 3, 1, -1, -3, -5, -7, -9, -11, -13, -15]
    @noise_periods [8, 16, 32, 48, 64, 80, 96, 112]

    @jump (fn ->
             import Bitwise

             for width7 <- 0..1, power <- 0..15, group <- 0..2, bits <- 0..31 do
               Enum.reduce(1..(1 <<< power), bits <<< (group * 5), fn _, state ->
                 feedback = bxor(state, state >>> 1) &&& 1
                 state = state >>> 1 ||| feedback <<< 14

                 if width7 == 1,
                   do: (state &&& bxor(0x40, 0x7FFF)) ||| feedback <<< 6,
                   else: state
               end)
             end
           end).()

    @impl true
    def event_driven?, do: true

    @impl true
    def prepare(%Beamicom.GB.APU{} = apu) do
      {t1, t2, t3, t4} = apu.render_triggers

      %{
        sample_phase: apu.sample_phase,
        p1_timer: apu.ch1.timer,
        p1_position: apu.ch1.duty_pos,
        p1_trigger: t1,
        p2_timer: apu.ch2.timer,
        p2_position: apu.ch2.duty_pos,
        p2_trigger: t2,
        wave_timer: apu.ch3.timer,
        wave_position: apu.ch3.position,
        wave_sample: apu.ch3.sample_buffer,
        wave_trigger: t3,
        noise_timer: apu.ch4.timer,
        noise_lfsr: apu.ch4.lfsr,
        noise_trigger: t4
      }
      |> tensor_state()
      |> Nx.backend_copy({EXLA.Backend, client: :host})
    end

    @impl true
    def render_events(state, segments, dots, expected_samples) do
      if length(segments) > @capacity, do: raise("Game Boy APU event block exceeds capacity")

      unless Enum.sum(Enum.map(segments, &hd/1)) == dots,
        do: raise("Game Boy APU event timeline mismatch")

      padded = segments ++ List.duplicate(List.duplicate(0, @width), @capacity - length(segments))
      rows = Nx.tensor(padded, type: :s32) |> Nx.backend_copy({EXLA.Backend, client: :host})

      count =
        Nx.tensor(length(segments), type: :s32) |> Nx.backend_copy({EXLA.Backend, client: :host})

      args = [state, rows, count]
      kind = if expected_samples <= @steady_samples, do: :steady, else: :boot
      {state, pcm, samples} = apply(compiled(kind, args), args)
      samples = Nx.to_number(samples)
      bytes = pcm |> Nx.to_binary() |> binary_part(0, samples * 4)
      {samples, bytes, state}
    end

    @impl true
    def snapshot(state), do: Nx.backend_copy(state, Nx.BinaryBackend)

    @impl true
    def restore(state), do: Nx.backend_copy(state, {EXLA.Backend, client: :host})

    defn run(state, rows, row_count) do
      pcm = Nx.broadcast(Nx.tensor(0, type: :s16), {@steady_samples, 2})

      {state, pcm, output, _, _, _} =
        while {state, pcm, output = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
               rows, row_count},
              index < row_count and output < @steady_samples do
          row = rows[index]
          state = apply_triggers(state, row)
          {state, pcm, output} = synth_segment(state, row, pcm, output)
          {state, pcm, output, index + 1, rows, row_count}
        end

      {state, pcm, output}
    end

    defn run_boot(state, rows, row_count) do
      pcm = Nx.broadcast(Nx.tensor(0, type: :s16), {@boot_samples, 2})

      {state, pcm, output, _, _, _} =
        while {state, pcm, output = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
               rows, row_count},
              index < row_count and output < @boot_samples do
          row = rows[index]
          state = apply_triggers(state, row)
          {state, pcm, output} = synth_segment(state, row, pcm, output)
          {state, pcm, output, index + 1, rows, row_count}
        end

      {state, pcm, output}
    end

    defnp synth_segment(state, row, pcm, output) do
      duration = row[0]
      total = state.sample_phase + duration * @sample_rate
      count = Nx.quotient(total, @clock_rate)
      indexes = Nx.iota({@segment_samples}, type: :s32) + 1

      offsets =
        Nx.quotient(indexes * @clock_rate - state.sample_phase + @sample_rate - 1, @sample_rate)

      sample_states = clock(state, row, offsets)
      values = mix(sample_states, row)
      pcm = Nx.put_slice(pcm, [output, 0], values)
      state = clock(state, row, duration)
      state = %{state | sample_phase: total - count * @clock_rate}
      {state, pcm, output + count}
    end

    defnp apply_triggers(state, row) do
      p1_period = (2048 - row[7]) * 4
      p2_period = (2048 - row[13]) * 4
      wave_period = (2048 - row[19]) * 2
      noise_period = Nx.take(Nx.tensor(@noise_periods, type: :s32), row[42]) * pow2(row[40])
      p1 = row[9] != state.p1_trigger
      p2 = row[15] != state.p2_trigger
      wave = row[20] != state.wave_trigger
      noise = row[43] != state.noise_trigger

      %{
        state
        | p1_timer: Nx.select(p1, p1_period, state.p1_timer),
          p1_trigger: row[9],
          p2_timer: Nx.select(p2, p2_period, state.p2_timer),
          p2_trigger: row[15],
          wave_timer: Nx.select(wave, wave_period, state.wave_timer),
          wave_position: Nx.select(wave, 0, state.wave_position),
          wave_trigger: row[20],
          noise_timer: Nx.select(noise, noise_period, state.noise_timer),
          noise_lfsr: Nx.select(noise, 0x7FFF, state.noise_lfsr),
          noise_trigger: row[43]
      }
    end

    defnp clock(state, row, dots) do
      {p1_timer, p1_position} =
        pulse_clock(state.p1_timer, state.p1_position, row[7], row[4] != 0, dots)

      {p2_timer, p2_position} =
        pulse_clock(state.p2_timer, state.p2_position, row[13], row[10] != 0, dots)

      {wave_timer, wave_position, wave_sample} =
        wave_clock(state.wave_timer, state.wave_position, state.wave_sample, row, dots)

      {noise_timer, noise_lfsr} =
        noise_clock(state.noise_timer, state.noise_lfsr, row, dots)

      %{
        state
        | p1_timer: p1_timer,
          p1_position: p1_position,
          p2_timer: p2_timer,
          p2_position: p2_position,
          wave_timer: wave_timer,
          wave_position: wave_position,
          wave_sample: wave_sample,
          noise_timer: noise_timer,
          noise_lfsr: noise_lfsr
      }
    end

    defnp pulse_clock(timer, position, frequency, enabled, dots) do
      period = (2048 - frequency) * 4
      crossed = dots >= timer
      after_first = Nx.max(dots - timer, 0)
      steps = Nx.select(crossed, 1 + Nx.quotient(after_first, period), 0)
      remainder = Nx.remainder(after_first, period)
      reloaded = Nx.select(remainder == 0, period, period - remainder)
      next_timer = Nx.select(crossed, reloaded, timer - dots)
      active = enabled and dots >= 0

      {Nx.select(active, next_timer, timer),
       Nx.select(active, band(position + steps, 7), position)}
    end

    defnp wave_clock(timer, position, sample, row, dots) do
      enabled = row[16] != 0
      period = (2048 - row[19]) * 2
      crossed = dots >= timer
      after_first = Nx.max(dots - timer, 0)
      steps = Nx.select(crossed, 1 + Nx.quotient(after_first, period), 0)
      remainder = Nx.remainder(after_first, period)
      reloaded = Nx.select(remainder == 0, period, period - remainder)
      next_timer = Nx.select(crossed, reloaded, timer - dots)
      next_position = band(position + steps, 31)
      byte = Nx.take(row, 21 + Nx.quotient(next_position, 2))
      next_sample = Nx.select(band(next_position, 1) == 0, shr(byte, 4), band(byte, 15))

      active = enabled and dots >= 0

      {Nx.select(active, next_timer, timer), Nx.select(active, next_position, position),
       Nx.select(active and crossed, next_sample, sample)}
    end

    defnp noise_clock(timer, lfsr, row, dots) do
      enabled = row[37] != 0 and row[40] < 14
      period = Nx.take(Nx.tensor(@noise_periods, type: :s32), row[42]) * pow2(row[40])
      crossed = dots >= timer
      after_first = Nx.max(dots - timer, 0)
      steps = Nx.select(crossed, 1 + Nx.quotient(after_first, period), 0)
      remainder = Nx.remainder(after_first, period)
      reloaded = Nx.select(remainder == 0, period, period - remainder)
      next_timer = Nx.select(crossed, reloaded, timer - dots)
      next_lfsr = noise_jump(lfsr, steps, row[41])
      active = enabled and dots >= 0
      {Nx.select(active, next_timer, timer), Nx.select(active, next_lfsr, lfsr)}
    end

    defnp mix(state, row) do
      p1 = pulse_output(state.p1_position, row[6], row[8], row[4] != 0 and row[5] != 0)
      p2 = pulse_output(state.p2_position, row[12], row[14], row[10] != 0 and row[11] != 0)
      wave = wave_output(state.wave_sample, row[18], row[16] != 0 and row[17] != 0)
      noise = noise_output(state.noise_lfsr, row[39], row[37] != 0 and row[38] != 0)
      route = row[3]
      right = routed(p1, p2, wave, noise, band(route, 15)) * (band(row[2], 7) + 1) * 64
      left = routed(p1, p2, wave, noise, shr(route, 4)) * (band(shr(row[2], 4), 7) + 1) * 64
      master = row[1] != 0 and p1 >= -32_768
      left = Nx.select(master, left, 0)
      right = Nx.select(master, right, 0)
      Nx.stack([left, right], axis: 1) |> Nx.clip(-32_768, 32_767) |> Nx.as_type(:s16)
    end

    defnp pulse_output(position, duty, volume, enabled) do
      bit = Nx.take(Nx.tensor(@duty, type: :s32), duty * 8 + position)
      Nx.select(enabled and position >= 0, Nx.take(Nx.tensor(@dac, type: :s32), bit * volume), 0)
    end

    defnp wave_output(sample, level, enabled) do
      shifted = Nx.select(level == 0, 0, shr(sample, Nx.max(level - 1, 0)))
      value = Nx.select(level == 0, 15, Nx.take(Nx.tensor(@dac, type: :s32), shifted))
      Nx.select(enabled and sample >= 0, value, 0)
    end

    defnp noise_output(lfsr, volume, enabled) do
      index = band(Nx.bitwise_xor(lfsr, 1), 1) * volume
      Nx.select(enabled and lfsr >= 0, Nx.take(Nx.tensor(@dac, type: :s32), index), 0)
    end

    defnp routed(p1, p2, wave, noise, route) do
      present = p1 >= -32_768

      Nx.select(band(route, 1) != 0 and present, p1, 0) +
        Nx.select(band(route, 2) != 0 and present, p2, 0) +
        Nx.select(band(route, 4) != 0 and present, wave, 0) +
        Nx.select(band(route, 8) != 0 and present, noise, 0)
    end

    deftransformp noise_jump(state, steps, width7) do
      table = Nx.tensor(@jump, type: :s32)

      Enum.reduce(0..15, state, fn power, current ->
        offset = Nx.multiply(Nx.add(Nx.multiply(width7, 16), power), 96)

        transformed =
          Nx.bitwise_xor(
            Nx.bitwise_xor(
              Nx.take(table, Nx.add(offset, Nx.bitwise_and(current, 31))),
              Nx.take(
                table,
                Nx.add(Nx.add(offset, 32), Nx.bitwise_and(Nx.right_shift(current, 5), 31))
              )
            ),
            Nx.take(
              table,
              Nx.add(Nx.add(offset, 64), Nx.bitwise_and(Nx.right_shift(current, 10), 31))
            )
          )

        Nx.select(
          Nx.not_equal(Nx.bitwise_and(Nx.right_shift(steps, power), 1), 0),
          transformed,
          current
        )
      end)
    end

    defnp(pow2(shift), do: Nx.left_shift(1, shift))
    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(shr(a, b), do: Nx.right_shift(a, b))

    defp tensor_state(state),
      do: Map.new(state, fn {key, value} -> {key, Nx.tensor(value, type: :s32)} end)

    defp compiled(kind, args) do
      key = {__MODULE__, kind, :compiled}

      case :persistent_term.get(key, nil) do
        nil ->
          function = if kind == :steady, do: &run/3, else: &run_boot/3
          compiled = EXLA.compile(function, Enum.map(args, &Nx.to_template/1), client: :host)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end
