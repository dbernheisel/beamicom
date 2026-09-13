defmodule Beamicom.NES.Nx.APU do
  @moduledoc "Resident numeric 2A03/MMC5 oscillator, sequencer, mixer, and filter state. DMC levels are supplied by the native control path."
  import Nx.Defn
  @pulse for(n <- 0..30, do: if(n == 0, do: 0.0, else: 95.52 / (8128.0 / n + 100)))
  @tnd for(n <- 0..202, do: if(n == 0, do: 0.0, else: 163.67 / (24329.0 / n + 100)))
  @m5 for(n <- 0..30, do: if(n == 0, do: 0.0, else: 95.88 / (8128 / n + 100)))
  @pcm for(n <- 0..255, do: n / 255 * 0.25)
  @ratio 44_100 / 1_789_773
  # LFSR evolution is linear over XOR. Three 5-bit lookup chunks exactly
  # reconstruct any 15-bit state after 0..32 steps, for either feedback tap.
  @noise_jump (fn ->
                 import Bitwise

                 for tap <- [1, 6], steps <- 0..32, group <- 0..2, bits <- 0..31 do
                   Enum.reduce(1..steps//1, bits <<< (group * 5), fn _, s ->
                     s >>> 1 ||| (bxor(s, s >>> tap) &&& 1) <<< 14
                   end)
                 end
               end).()
  def pack(s) do
    if s.sunsoft5b != nil,
      do: raise(ArgumentError, "Sunsoft 5B is not implemented in the Nx APU renderer")

    s
    |> Map.from_struct()
    |> Map.drop([
      :samples,
      :dmc_samples,
      :dmc_silent_samples,
      :external_dmc_samples,
      :dmc,
      :sunsoft5b
    ])
    |> pack_map()
  end

  defp pack_map(s) do
    Map.new(s, fn {k, v} ->
      t =
        cond do
          is_struct(v) -> pack_map(Map.from_struct(v))
          is_float(v) -> Nx.tensor(v, type: :f64)
          is_boolean(v) -> Nx.tensor(if(v, do: 1, else: 0), type: :s32)
          true -> Nx.tensor(v, type: :s32)
        end

      {k, t}
    end)
  end

  @doc "Advance without register writes; return resident state, PCM buffer, valid count and unconsumed cycles."
  defn run(s, cycles) do
    {s, left, buffer, count} =
      while {s, left = cycles, buffer = Nx.broadcast(Nx.tensor(0, type: :s16), {1024}),
             count = Nx.tensor(0, type: :s32)},
            left > 0 and count < 1024 do
        to_sample =
          Nx.max(
            1,
            Nx.as_type(Nx.ceil((1.0 - s.sample_acc) / Nx.tensor(@ratio, type: :f64)), :s32)
          )

        last = Nx.select(s.frame_mode == 5, 37281, 29829)

        target =
          cond do
            s.seq_cycle < 7457 -> 7457
            s.seq_cycle < 14913 -> 14913
            s.seq_cycle < 22371 -> 22371
            s.seq_cycle < last -> last
            true -> last + 1
          end

        dc = Nx.min(left, Nx.min(to_sample, target - s.seq_cycle))
        dc = Nx.select(s.m5_active != 0, Nx.min(dc, 7457 - s.m5seq), dc)
        {s, pcm, emitted} = advance(s, dc)
        buffer = Nx.put_slice(buffer, [count], Nx.reshape(pcm, {1}))
        {s, left - dc, buffer, count + emitted}
      end

    {s, buffer, count, left}
  end

  # dc ends at a sample/sequencer event, exactly as the reference advance/2.
  defn advance(s, dc) do
    clocks = Nx.quotient(dc + s.apu_tick, 2)
    {p1t, p1s} = pulse(s.p1_timer, s.p1_seq, s.pulse1.period, clocks)
    {p2t, p2s} = pulse(s.p2_timer, s.p2_seq, s.pulse2.period, clocks)
    {tt, steps} = counter(s.tri_timer, s.triangle.period, dc)

    ts =
      Nx.select(
        s.triangle.linear > 0 and s.triangle.length > 0 and s.triangle.period >= 2,
        band(s.tri_seq + steps, 31),
        s.tri_seq
      )

    {nt, steps} = counter(s.noise_timer, s.noise.period, clocks)

    {ns, steps, mode} =
      while {ns = s.noise_shift, steps, mode = s.noise.mode}, steps >= 32 do
        {noise_jump(ns, 32, mode), steps - 32, mode}
      end

    ns = noise_jump(ns, steps, mode)

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
        sample_acc: s.sample_acc + Nx.as_type(dc, :f64) * Nx.tensor(@ratio, type: :f64),
        apu_tick: int(s.apu_tick != Nx.remainder(dc, 2))
    }

    s = frame(s)
    {m1t, m1s} = pulse(s.m5p1_timer, s.m5p1_seq, s.m5p1.period, clocks)
    {m2t, m2s} = pulse(s.m5p2_timer, s.m5p2_seq, s.m5p2.period, clocks)
    m = s.m5seq + dc
    m5 = %{s | m5p1_timer: m1t, m5p1_seq: m1s, m5p2_timer: m2t, m5p2_seq: m2s, m5seq: m}

    m5clocked = %{
      m5
      | m5seq: Nx.tensor(0, type: :s32),
        m5p1: length_clock(envelope(m5.m5p1)),
        m5p2: length_clock(envelope(m5.m5p2))
    }

    m5 = select_state(m >= 7457, m5clocked, m5)
    s = select_state(s.m5_active != 0, m5, s)
    emit = s.sample_acc >= 1.0
    x = mix(s, 0)
    hp = Nx.tensor(0.987340, type: :f64) * (s.f_hp + x - s.f_hp_x)
    lp = s.f_lp + Nx.tensor(0.532680, type: :f64) * (hp - s.f_lp)
    pcm = Nx.as_type(Nx.clip(Nx.round(lp * 32767), -32768, 32767), :s16)

    s = %{
      s
      | sample_acc: Nx.select(emit, s.sample_acc - 1.0, s.sample_acc),
        f_hp: Nx.select(emit, hp, s.f_hp),
        f_hp_x: Nx.select(emit, x, s.f_hp_x),
        f_lp: Nx.select(emit, lp, s.f_lp)
    }

    {s, Nx.select(emit, pcm, Nx.tensor(0, type: :s16)), int(emit)}
  end

  defn counter(timer, period, clocks) do
    r = Nx.max(clocks - timer - 1, 0)

    {Nx.select(clocks <= timer, timer - clocks, period - Nx.remainder(r, period + 1)),
     Nx.select(clocks <= timer, 0, 1 + Nx.quotient(r, period + 1))}
  end

  defn pulse(timer, seq, period, clocks) do
    {timer, steps} = counter(timer, period, clocks)
    {timer, band(seq + steps, 7)}
  end

  defn envelope(p) do
    decay = Nx.select(p.env_decay > 0, p.env_decay - 1, Nx.select(p.halt != 0, 15, 0))

    %{
      p
      | env_start: Nx.tensor(0, type: :s32),
        env_decay: Nx.select(p.env_start != 0, 15, Nx.select(p.env_div == 0, decay, p.env_decay)),
        env_div: Nx.select(p.env_start != 0 or p.env_div == 0, p.vol, p.env_div - 1)
    }
  end

  defn(length_clock(p),
    do: %{p | length: Nx.select(p.halt == 0 and p.length > 0, p.length - 1, p.length)}
  )

  defnp linear(t) do
    %{
      t
      | linear: Nx.select(t.reload_flag != 0, t.linear_reload, Nx.max(t.linear - 1, 0)),
        reload_flag: int(t.reload_flag != 0 and t.control != 0)
    }
  end

  defnp target(p) do
    change = shr(p.period, p.sweep_shift)

    Nx.select(
      p.sweep_neg != 0,
      Nx.max(p.period - change - Nx.select(p.ones != 0, 0, 1), 0),
      p.period + change
    )
  end

  defnp sweep(p) do
    t = target(p)

    change =
      p.sweep_div == 0 and p.sweep_en != 0 and p.sweep_shift > 0 and p.period >= 8 and t <= 2047

    reload = p.sweep_div == 0 or p.sweep_reload != 0

    %{
      p
      | period: Nx.select(change, t, p.period),
        sweep_div: Nx.select(reload, p.sweep_period, p.sweep_div - 1),
        sweep_reload: Nx.tensor(0, type: :s32)
    }
  end

  defn frame(s) do
    last = Nx.select(s.frame_mode == 5, 37281, 29829)

    quarter =
      s.seq_cycle == 7457 or s.seq_cycle == 14913 or s.seq_cycle == 22371 or s.seq_cycle == last

    half = s.seq_cycle == 14913 or s.seq_cycle == last

    q = %{
      s
      | pulse1: envelope(s.pulse1),
        pulse2: envelope(s.pulse2),
        noise: envelope(s.noise),
        triangle: linear(s.triangle)
    }

    s = select_state(quarter, q, s)

    h = %{
      s
      | pulse1: sweep(length_clock(s.pulse1)),
        pulse2: sweep(length_clock(s.pulse2)),
        noise: length_clock(s.noise),
        triangle: length_clock(s.triangle)
    }

    s = select_state(half, h, s)

    %{
      s
      | frame_irq:
          Nx.select(
            s.frame_mode != 5 and s.seq_cycle == last,
            int(s.irq_inhibit == 0),
            s.frame_irq
          ),
        seq_cycle: Nx.select(s.seq_cycle >= last + 1, 0, s.seq_cycle)
    }
  end

  defnp level(p, seq, expansion) do
    duty = Nx.tensor([64, 96, 120, 159], type: :s32)
    valid = p.length != 0 and band(shr(Nx.take(duty, p.duty), 7 - seq), 1) != 0
    valid = valid and (expansion != 0 or (p.period >= 8 and target(p) <= 2047))
    Nx.select(valid, Nx.select(p.const != 0, p.vol, p.env_decay), 0)
  end

  defn mix(s, dmc) do
    pulse_table = Nx.tensor(@pulse, type: :f64)
    tnd_table = Nx.tensor(@tnd, type: :f64)
    m5_table = Nx.tensor(@m5, type: :f64)
    pcm_table = Nx.tensor(@pcm, type: :f64)
    tri = Nx.select(s.tri_seq < 16, 15 - s.tri_seq, s.tri_seq - 16)

    noise =
      Nx.select(
        s.noise.length == 0 or band(s.noise_shift, 1) == 1,
        0,
        Nx.select(s.noise.const != 0, s.noise.vol, s.noise.env_decay)
      )

    p = level(s.pulse1, s.p1_seq, 0) + level(s.pulse2, s.p2_seq, 0)
    m5 = level(s.m5p1, s.m5p1_seq, 1) + level(s.m5p2, s.m5p2_seq, 1)

    expansion =
      Nx.select(
        s.m5_active != 0,
        Nx.take(m5_table, m5) + Nx.take(pcm_table, s.m5pcm),
        Nx.tensor(0.0, type: :f64)
      )

    Nx.take(pulse_table, p) + Nx.take(tnd_table, 3 * tri + 2 * noise + dmc) + expansion
  end

  defnp(int(x), do: Nx.as_type(x, :s32))

  defnp noise_jump(ns, steps, mode) do
    table = Nx.tensor(@noise_jump, type: :s32)
    offset = (mode * 33 + steps) * 96

    Nx.bitwise_xor(
      Nx.bitwise_xor(
        table[offset + band(ns, 31)],
        table[offset + 32 + band(shr(ns, 5), 31)]
      ),
      table[offset + 64 + band(shr(ns, 10), 31)]
    )
  end

  deftransformp select_state(condition, a, b) do
    Map.new(a, fn {k, v} ->
      other = Map.fetch!(b, k)

      value =
        if is_map(v) and not is_struct(v, Nx.Tensor),
          do: select_state(condition, v, other),
          else: Nx.select(condition, v, other)

      {k, value}
    end)
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
