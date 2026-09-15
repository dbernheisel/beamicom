if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.BlockAPU do
    @moduledoc "Timestamped Nx audio blocks with vectorized fixed-point sample generation."
    import Nx.Defn
    alias Beamicom.NES.Nx.{APU, FrameAudioMath}

    @sample_rate 44_100
    @cpu_hz 1_789_773
    @oversample_ratio 192_000 / 1_789_773
    @width 128
    @buffer_capacity 1024 + @width
    @oversample_capacity 3200
    @input_capacity 4096
    @hp90_192k 0.997063
    @lp14k_192k 0.314193

    # Binary powers of the exact 15-bit linear noise transition. Arbitrary jumps
    # within an epoch require 13 stages, applied across all sample times at once.
    @jump (fn ->
             import Bitwise

             for tap <- [1, 6], power <- 0..12, group <- 0..2, bits <- 0..31 do
               Enum.reduce(1..(1 <<< power), bits <<< (group * 5), fn _, s ->
                 s >>> 1 ||| (bxor(s, s >>> tap) &&& 1) <<< 14
               end)
             end
           end).()

    def events(entries, cycles, capacity \\ 128) do
      if not is_integer(cycles) or cycles < 0 or cycles > 40_000 or not is_integer(capacity) or
           capacity < 1 or length(entries) > capacity,
         do: raise(ArgumentError, "block exceeds cycle/event capacity")

      Enum.reduce(entries, 0, fn {t, a, v}, last ->
        supported = a in 0x4000..0x4013 or a in [0x4015, 0x4017] or a in 0x5000..0x5015

        if not is_integer(t) or not is_integer(a) or not is_integer(v) or not supported or
             t < last or
             t > cycles or not ((v >= 0 and v <= 255) or (a == 0x4015 and v == -1)),
           do: raise(ArgumentError, "invalid/unsupported timestamped APU event")

        t
      end)

      rows =
        Enum.map(entries, &Tuple.to_list/1) ++
          List.duplicate([cycles + 1, 0, 0], capacity - length(entries))

      {Nx.tensor(rows, type: :s32), Nx.tensor(length(entries), type: :s32)}
    end

    defn run(s, events, event_count, cycles, dmc, expansion) do
      {s, pos, index, pcm, count, _, _, _, _, _} =
        while {s, pos = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
               pcm = Nx.broadcast(Nx.tensor(0, type: :s64), {@buffer_capacity}),
               count = Nx.tensor(0, type: :s32), events, event_count, cycles, dmc, expansion},
              count < 1024 and (pos < cycles or (index < event_count and events[index][0] == pos)) do
          next_write = Nx.select(index < event_count, events[index][0], cycles + 1)

          if next_write == pos do
            s = Beamicom.NES.Nx.APUWrites.apply(s, events[index][1], events[index][2])
            {s, pos, index + 1, pcm, count, events, event_count, cycles, dmc, expansion}
          else
            dc = Nx.min(cycles - pos, Nx.min(next_write - pos, boundary(s)))
            {s, used, pcm, count} = segment(s, dc, pcm, count, dmc, expansion)
            {s, pos + used, index, pcm, count, events, event_count, cycles, dmc, expansion}
          end
        end

      {s, pcm, count, cycles - pos, index}
    end

    @doc "Synthesize at 192 kHz, then windowed-sinc decimate to one fixed 800-sample 48 kHz frame."
    defn run_frame_48(s, events, event_count, cycles, dmc, expansion, kernel) do
      {s, pos, index, samples, count, _, _, _, _, _} =
        while {s, pos = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
               samples = Nx.broadcast(Nx.tensor(0, type: :f32), {@oversample_capacity}),
               count = Nx.tensor(0, type: :s32), events, event_count, cycles, dmc, expansion},
              count < @oversample_capacity and
                (pos < cycles or (index < event_count and events[index][0] == pos)) do
          next_write = Nx.select(index < event_count, events[index][0], cycles + 1)

          if next_write == pos do
            s = Beamicom.NES.Nx.APUWrites.apply(s, events[index][1], events[index][2])
            {s, pos, index + 1, samples, count, events, event_count, cycles, dmc, expansion}
          else
            dc = Nx.min(cycles - pos, Nx.min(next_write - pos, boundary(s)))
            {s, used, samples, count} = oversampled_segment(s, dc, samples, count, dmc, expansion)
            {s, pos + used, index, samples, count, events, event_count, cycles, dmc, expansion}
          end
        end

      # NTSC frames are slightly shorter than 1/60 second. The public frame
      # contract is fixed at 800 samples, so extend the final filtered level to
      # 3200 before the 4x decimator. Oscillator state advances only real cycles.
      last = samples[Nx.max(count - 1, 0)]
      valid = Nx.iota({@oversample_capacity}, type: :s32) < count
      samples = Nx.select(valid, samples, last)
      pcm = FrameAudioMath.decimate_4x(samples, kernel)
      {s, pcm, Nx.tensor(800, type: :s32), cycles - pos, index, count}
    end

    defn boundary(s) do
      last = Nx.select(s.frame_mode == 5, 37281, 29829)

      target =
        Nx.select(
          s.seq_cycle < 7457,
          7457,
          Nx.select(
            s.seq_cycle < 14913,
            14913,
            Nx.select(s.seq_cycle < 22371, 22371, Nx.select(s.seq_cycle < last, last, last + 1))
          )
        )

      Nx.select(
        s.m5_active != 0,
        Nx.min(target - s.seq_cycle, 7457 - s.m5seq),
        target - s.seq_cycle
      )
    end

    defnp segment(s, dc, pcm, count, dmc, expansion) do
      indices = Nx.iota({@width}, type: :s64) + 1

      offsets =
        Nx.quotient(indices * @cpu_hz - s.sample_acc + @sample_rate - 1, @sample_rate)
        |> Nx.as_type(:s32)

      available = Nx.quotient(s.sample_acc + Nx.as_type(dc, :s64) * @sample_rate, @cpu_hz)
      capacity = Nx.min(@width, 1024 - count)
      n = Nx.min(available, Nx.as_type(capacity, :s64)) |> Nx.as_type(:s32)
      nth_offset = Nx.take(offsets, Nx.max(n - 1, 0))
      used = Nx.select(available > capacity, nth_offset, dc)
      offsets = Nx.min(offsets, used)

      acc =
        s.sample_acc + Nx.as_type(used, :s64) * @sample_rate -
          Nx.as_type(n, :s64) * @cpu_hz

      # All waveform evaluations in this epoch run as tensor operations.
      sample_indices = Nx.min(count + Nx.iota({@width}, type: :s32), 1023)

      values =
        APU.mix_fixed(clock(s, offsets), Nx.take(dmc, sample_indices)) +
          Nx.take(expansion, sample_indices)

      final = clock(s, used)
      valid = Nx.iota({@width}, type: :s32) < n
      values = Nx.select(valid, values, 0)
      pcm = Nx.put_slice(pcm, [count], values)

      {%{final | sample_acc: acc}, used, pcm, count + n}
    end

    defnp oversampled_segment(s, dc, samples, count, dmc, expansion) do
      {acc, used, n, offsets, _, _} =
        while {acc = s.sample_acc, used = Nx.tensor(0, type: :s32), n = Nx.tensor(0, type: :s32),
               offsets = Nx.broadcast(Nx.tensor(0, type: :s32), {@width}), dc, count},
              used < dc and n < @width and count + n < @oversample_capacity do
          step =
            Nx.min(
              dc - used,
              Nx.max(
                1,
                Nx.as_type(
                  Nx.ceil((1.0 - acc) / Nx.tensor(@oversample_ratio, type: :f64)),
                  :s32
                )
              )
            )

          acc = acc + Nx.as_type(step, :f64) * Nx.tensor(@oversample_ratio, type: :f64)
          emit = acc >= 1.0
          used = used + step
          offsets = Nx.put_slice(offsets, [n], Nx.reshape(used, {1}))
          {Nx.select(emit, acc - 1.0, acc), used, n + Nx.as_type(emit, :s32), offsets, dc, count}
        end

      sample_indices = Nx.min(count + Nx.iota({@width}, type: :s32), @input_capacity - 1)

      values =
        APU.mix(clock(s, offsets), Nx.take(dmc, sample_indices)) +
          Nx.take(expansion, sample_indices)

      final = clock(s, used)

      {hp, previous, lp, samples, _, _, _, _} =
        while {hp = s.f_hp, previous = s.f_hp_x, lp = s.f_lp, samples,
               i = Nx.tensor(0, type: :s32), values, n, count},
              i < n do
          x = values[i]
          hp = Nx.tensor(@hp90_192k, type: :f64) * (hp + x - previous)
          lp = lp + Nx.tensor(@lp14k_192k, type: :f64) * (hp - lp)
          samples = Nx.put_slice(samples, [count + i], Nx.reshape(Nx.as_type(lp, :f32), {1}))
          {hp, x, lp, samples, i + 1, values, n, count}
        end

      {%{final | sample_acc: acc, f_hp: hp, f_hp_x: previous, f_lp: lp}, used, samples, count + n}
    end

    defn clock(s, dc) do
      clocks = Nx.quotient(dc + s.apu_tick, 2)
      {p1t, p1s} = APU.pulse(s.p1_timer, s.p1_seq, s.pulse1.period, clocks)
      {p2t, p2s} = APU.pulse(s.p2_timer, s.p2_seq, s.pulse2.period, clocks)
      {tt, steps} = APU.counter(s.tri_timer, s.triangle.period, dc)

      ts =
        Nx.select(
          s.triangle.linear > 0 and s.triangle.length > 0 and s.triangle.period >= 2,
          Nx.bitwise_and(s.tri_seq + steps, 31),
          s.tri_seq
        )

      {nt, steps} = APU.counter(s.noise_timer, s.noise.period, clocks)
      ns = noise(s.noise_shift, steps, s.noise.mode)

      s = %{
        s
        | p1_timer: p1t,
          p1_seq: p1s,
          p2_timer: p2t,
          p2_seq: p2s,
          tri_timer: tt,
          tri_seq: ts,
          noise_timer: nt,
          noise_shift: ns,
          seq_cycle: s.seq_cycle + dc,
          apu_tick: Nx.as_type(s.apu_tick != Nx.remainder(dc, 2), :s32)
      }

      s = APU.frame(s)
      {m1t, m1s} = APU.pulse(s.m5p1_timer, s.m5p1_seq, s.m5p1.period, clocks)
      {m2t, m2s} = APU.pulse(s.m5p2_timer, s.m5p2_seq, s.m5p2.period, clocks)
      m = s.m5seq + dc
      m5 = %{s | m5p1_timer: m1t, m5p1_seq: m1s, m5p2_timer: m2t, m5p2_seq: m2s, m5seq: m}

      ticked = %{
        m5
        | m5seq: Nx.tensor(0, type: :s32),
          m5p1: APU.length_clock(APU.envelope(m5.m5p1)),
          m5p2: APU.length_clock(APU.envelope(m5.m5p2))
      }

      select(s.m5_active != 0, select(m >= 7457, ticked, m5), s)
    end

    deftransformp noise(state, steps, mode) do
      table = Nx.tensor(@jump, type: :s32)

      Enum.reduce(0..12, state, fn power, ns ->
        offset = Nx.multiply(Nx.add(Nx.multiply(mode, 13), power), 96)

        transformed =
          Nx.bitwise_xor(
            Nx.bitwise_xor(
              Nx.take(table, Nx.add(offset, Nx.bitwise_and(ns, 31))),
              Nx.take(
                table,
                Nx.add(Nx.add(offset, 32), Nx.bitwise_and(Nx.right_shift(ns, 5), 31))
              )
            ),
            Nx.take(table, Nx.add(Nx.add(offset, 64), Nx.bitwise_and(Nx.right_shift(ns, 10), 31)))
          )

        Nx.select(
          Nx.not_equal(Nx.bitwise_and(Nx.right_shift(steps, power), 1), 0),
          transformed,
          ns
        )
      end)
    end

    deftransformp select(condition, a, b) do
      Map.new(a, fn {k, v} ->
        other = Map.fetch!(b, k)

        {k,
         if(is_map(v) and not is_struct(v, Nx.Tensor),
           do: select(condition, v, other),
           else: Nx.select(condition, v, other)
         )}
      end)
    end
  end
end
