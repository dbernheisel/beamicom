defmodule Beamicom.NES.Nx.BlockAPU do
  @moduledoc "Timestamped Nx audio blocks: vector waveform evaluation between control events, sequential filters."
  import Nx.Defn
  alias Beamicom.NES.Nx.APU
  @ratio 44_100 / 1_789_773
  @width 128
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

      if not is_integer(t) or not is_integer(a) or not is_integer(v) or not supported or t < last or
           t > cycles or not ((v >= 0 and v <= 255) or (a == 0x4015 and v == -1)),
         do: raise(ArgumentError, "invalid/unsupported timestamped APU event")

      t
    end)

    rows =
      Enum.map(entries, &Tuple.to_list/1) ++
        List.duplicate([cycles + 1, 0, 0], capacity - length(entries))

    {Nx.tensor(rows, type: :s32), Nx.tensor(length(entries), type: :s32)}
  end

  defn run(s, events, event_count, cycles, dmc) do
    {s, pos, index, pcm, count, _, _, _, _} =
      while {s, pos = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
             pcm = Nx.broadcast(Nx.tensor(0, type: :s16), {1024}),
             count = Nx.tensor(0, type: :s32), events, event_count, cycles, dmc},
            count < 1024 and (pos < cycles or (index < event_count and events[index][0] == pos)) do
        next_write = Nx.select(index < event_count, events[index][0], cycles + 1)

        if next_write == pos do
          s = Beamicom.NES.Nx.APUWrites.apply(s, events[index][1], events[index][2])
          {s, pos, index + 1, pcm, count, events, event_count, cycles, dmc}
        else
          dc = Nx.min(cycles - pos, Nx.min(next_write - pos, boundary(s)))
          {s, used, pcm, count} = segment(s, dc, pcm, count, dmc)
          {s, pos + used, index, pcm, count, events, event_count, cycles, dmc}
        end
      end

    {s, pcm, count, cycles - pos, index}
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

  defnp segment(s, dc, pcm, count, dmc) do
    # Only the sample clock is recurrent here; channel maps are not loop carries.
    {acc, used, n, offsets, _, _} =
      while {acc = s.sample_acc, used = Nx.tensor(0, type: :s32), n = Nx.tensor(0, type: :s32),
             offsets = Nx.broadcast(Nx.tensor(0, type: :s32), {@width}), dc, count},
            used < dc and n < @width and count + n < 1024 do
        step =
          Nx.min(
            dc - used,
            Nx.max(1, Nx.as_type(Nx.ceil((1.0 - acc) / Nx.tensor(@ratio, type: :f64)), :s32))
          )

        acc = acc + Nx.as_type(step, :f64) * Nx.tensor(@ratio, type: :f64)
        emit = acc >= 1.0
        used = used + step
        offsets = Nx.put_slice(offsets, [n], Nx.reshape(used, {1}))
        {Nx.select(emit, acc - 1.0, acc), used, n + Nx.as_type(emit, :s32), offsets, dc, count}
      end

    # All waveform evaluations in this epoch run as tensor operations.
    sample_indices = Nx.min(count + Nx.iota({@width}, type: :s32), 1023)
    values = APU.mix(clock(s, offsets), Nx.take(dmc, sample_indices))
    final = clock(s, used)

    {hp, previous, lp, pcm, _, _, _, _} =
      while {hp = s.f_hp, previous = s.f_hp_x, lp = s.f_lp, pcm, i = Nx.tensor(0, type: :s32),
             values, n, count},
            i < n do
        x = values[i]
        hp = Nx.tensor(0.987340, type: :f64) * (hp + x - previous)
        lp = lp + Nx.tensor(0.532680, type: :f64) * (hp - lp)
        sample = Nx.as_type(Nx.clip(Nx.round(lp * 32767), -32768, 32767), :s16)
        pcm = Nx.put_slice(pcm, [count + i], Nx.reshape(sample, {1}))
        {hp, x, lp, pcm, i + 1, values, n, count}
      end

    {%{final | sample_acc: acc, f_hp: hp, f_hp_x: previous, f_lp: lp}, used, pcm, count + n}
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
            Nx.take(table, Nx.add(Nx.add(offset, 32), Nx.bitwise_and(Nx.right_shift(ns, 5), 31)))
          ),
          Nx.take(table, Nx.add(Nx.add(offset, 64), Nx.bitwise_and(Nx.right_shift(ns, 10), 31)))
        )

      Nx.select(Nx.not_equal(Nx.bitwise_and(Nx.right_shift(steps, power), 1), 0), transformed, ns)
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
