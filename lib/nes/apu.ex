defmodule Beamicom.NES.APU do
  @moduledoc """
  2A03 APU (spec §2, §12 step 10): two pulse channels, triangle, and noise, with
  envelopes, sweep, length counters, the frame-sequencer, and the nonlinear
  mixer. Clocked per CPU cycle by `tick/2`, emitting 44.1kHz mono samples that a
  sink drains with `take_samples/1`.

  DMC (delta modulation) is stubbed — its sample DMA is deferred (ponytail: add
  when a game needs it).

  ## Sources
    * NESdev Wiki — APU, APU pulse/triangle/noise, APU Frame Counter, APU Mixer.
  """

  import Bitwise

  @compile {:inline, bool: 2, clamp: 1, tri_level: 1, clock_length: 1, sweep_target: 1, filter: 2}

  @sample_rate 44_100
  @cpu_hz 1_789_773
  @rate_ratio @sample_rate / @cpu_hz
  @duty {0b01000000, 0b01100000, 0b01111000, 0b10011111}
  @tri_seq {15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            10, 11, 12, 13, 14, 15}
  @length {10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, 12, 16, 24, 18, 48, 20,
           96, 22, 192, 24, 72, 26, 16, 28, 32, 30}
  @noise_periods {4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068}
  # 4-step frame-sequencer boundaries in CPU cycles.
  @frame4 {7457, 14913, 22371, 29829}
  @frame5 {7457, 14913, 22371, 37281}

  defstruct pulse1: nil,
            pulse2: nil,
            triangle: nil,
            noise: nil,
            frame_mode: 4,
            irq_inhibit: false,
            frame_irq: false,
            seq_cycle: 0,
            apu_tick: false,
            # Hot per-segment channel state kept top-level (not in the channel maps)
            # so advance/2 updates plain integer fields instead of copying six
            # ~18-key maps every segment. Channel config stays in the maps.
            p1_timer: 0,
            p1_seq: 0,
            p2_timer: 0,
            p2_seq: 0,
            tri_timer: 0,
            tri_seq: 0,
            noise_timer: 0,
            noise_shift: 1,
            m5p1_timer: 0,
            m5p1_seq: 0,
            m5p2_timer: 0,
            m5p2_seq: 0,
            sample_acc: 0.0,
            samples: [],
            # RCA output filter chain state (see filter/2): prev in/out for the
            # DC-blocking high-pass, prev out for the low-pass.
            f_hp: 0.0,
            f_hp_x: 0.0,
            f_lp: 0.0,
            # MMC5 sound: two sweep-less pulses + raw PCM, own 240Hz sequencer.
            # `m5_active` gates all of it — set once on the first MMC5 sound write
            # so non-MMC5 games skip the extra channels/sequencer/mixer entirely.
            m5_active: false,
            m5p1: nil,
            m5p2: nil,
            m5pcm: 0,
            m5seq: 0,
            # Un-run CPU cycles owed to the APU; run lazily in bulk (see tick/2).
            pending: 0

  defp pulse do
    %{
      duty: 0,
      period: 0,
      length: 0,
      halt: false,
      const: false,
      vol: 0,
      env_start: false,
      env_div: 0,
      env_decay: 0,
      sweep_en: false,
      sweep_period: 0,
      sweep_neg: false,
      sweep_shift: 0,
      sweep_div: 0,
      sweep_reload: false,
      ones: false,
      enabled: false
    }
  end

  defp tri do
    %{
      period: 0,
      length: 0,
      halt: false,
      control: false,
      linear: 0,
      linear_reload: 0,
      reload_flag: false,
      enabled: false
    }
  end

  defp noise do
    %{
      period: 0,
      mode: false,
      length: 0,
      halt: false,
      const: false,
      vol: 0,
      env_start: false,
      env_div: 0,
      env_decay: 0,
      enabled: false
    }
  end

  def new do
    %__MODULE__{
      pulse1: pulse(),
      pulse2: %{pulse() | ones: true},
      triangle: tri(),
      noise: noise(),
      m5p1: pulse(),
      m5p2: pulse()
    }
  end

  @doc "MMC5 sound register write ($5000-$5015)."
  def mmc5_write(apu, addr, val) do
    apu = %{flush(apu) | m5_active: true}

    case addr do
      a when a in 0x5000..0x5003 ->
        apu = %{apu | m5p1: pulse_reg(apu.m5p1, a - 0x5000, val)}
        if a == 0x5003, do: %{apu | m5p1_seq: 0}, else: apu

      a when a in 0x5004..0x5007 ->
        apu = %{apu | m5p2: pulse_reg(apu.m5p2, a - 0x5004, val)}
        if a == 0x5007, do: %{apu | m5p2_seq: 0}, else: apu

      0x5011 ->
        %{apu | m5pcm: val}

      0x5015 ->
        %{apu | m5p1: m5_enable(apu.m5p1, val &&& 1), m5p2: m5_enable(apu.m5p2, val &&& 2)}

      _ ->
        apu
    end
  end

  defp m5_enable(ch, 0), do: %{ch | enabled: false, length: 0}
  defp m5_enable(ch, _), do: %{ch | enabled: true}

  @doc "Whether the frame-counter IRQ line is asserted."
  def irq?(%__MODULE__{frame_irq: irq}), do: irq

  @doc "Drain the generated samples (oldest first)."
  def take_samples(apu) do
    apu = flush(apu)
    {Enum.reverse(apu.samples), %{apu | samples: []}}
  end

  # --- register writes ($4000-$4017) ---
  # Run the backlog first so the write lands at the right point in time.

  def write(apu, addr, val), do: write_reg(flush(apu), addr, val)

  defp write_reg(apu, addr, val) when addr in 0x4000..0x4003 do
    apu = %{apu | pulse1: pulse_reg(apu.pulse1, addr - 0x4000, val)}
    if addr == 0x4003, do: %{apu | p1_seq: 0}, else: apu
  end

  defp write_reg(apu, addr, val) when addr in 0x4004..0x4007 do
    apu = %{apu | pulse2: pulse_reg(apu.pulse2, addr - 0x4004, val)}
    if addr == 0x4007, do: %{apu | p2_seq: 0}, else: apu
  end

  defp write_reg(apu, addr, val) when addr in 0x4008..0x400B do
    %{apu | triangle: tri_reg(apu.triangle, addr - 0x4008, val)}
  end

  defp write_reg(apu, addr, val) when addr in 0x400C..0x400F do
    %{apu | noise: noise_reg(apu.noise, addr - 0x400C, val)}
  end

  defp write_reg(apu, 0x4015, val), do: status_write(apu, val)
  defp write_reg(apu, 0x4017, val), do: frame_write(apu, val)
  defp write_reg(apu, _addr, _val), do: apu

  @doc "Read $4015 status: length-counter-active flags + frame IRQ (clears the IRQ)."
  def read_status(apu) do
    apu = flush(apu)

    b =
      bool(apu.pulse1.length > 0, 0x01) ||| bool(apu.pulse2.length > 0, 0x02) |||
        bool(apu.triangle.length > 0, 0x04) ||| bool(apu.noise.length > 0, 0x08) |||
        bool(apu.frame_irq, 0x40)

    {b, %{apu | frame_irq: false}}
  end

  defp bool(true, mask), do: mask
  defp bool(false, _mask), do: 0

  defp pulse_reg(p, 0, v) do
    %{p | duty: v >>> 6, halt: (v &&& 0x20) != 0, const: (v &&& 0x10) != 0, vol: v &&& 0x0F}
  end

  defp pulse_reg(p, 1, v) do
    %{
      p
      | sweep_en: (v &&& 0x80) != 0,
        sweep_period: v >>> 4 &&& 0x07,
        sweep_neg: (v &&& 0x08) != 0,
        sweep_shift: v &&& 0x07,
        sweep_reload: true
    }
  end

  defp pulse_reg(p, 2, v), do: %{p | period: (p.period &&& 0x700) ||| v}

  defp pulse_reg(p, 3, v) do
    period = (p.period &&& 0xFF) ||| (v &&& 0x07) <<< 8
    length = if p.enabled, do: elem(@length, v >>> 3), else: p.length
    %{p | period: period, length: length, env_start: true}
  end

  defp tri_reg(t, 0, v) do
    %{t | control: (v &&& 0x80) != 0, halt: (v &&& 0x80) != 0, linear_reload: v &&& 0x7F}
  end

  defp tri_reg(t, 2, v), do: %{t | period: (t.period &&& 0x700) ||| v}

  defp tri_reg(t, 3, v) do
    length = if t.enabled, do: elem(@length, v >>> 3), else: t.length
    %{t | period: (t.period &&& 0xFF) ||| (v &&& 0x07) <<< 8, length: length, reload_flag: true}
  end

  defp tri_reg(t, _, _), do: t

  defp noise_reg(n, 0, v) do
    %{n | halt: (v &&& 0x20) != 0, const: (v &&& 0x10) != 0, vol: v &&& 0x0F}
  end

  defp noise_reg(n, 2, v) do
    %{n | mode: (v &&& 0x80) != 0, period: elem(@noise_periods, v &&& 0x0F)}
  end

  defp noise_reg(n, 3, v) do
    length = if n.enabled, do: elem(@length, v >>> 3), else: n.length
    %{n | length: length, env_start: true}
  end

  defp noise_reg(n, _, _), do: n

  defp status_write(apu, v) do
    %{
      apu
      | pulse1: enable(apu.pulse1, (v &&& 0x01) != 0),
        pulse2: enable(apu.pulse2, (v &&& 0x02) != 0),
        triangle: enable(apu.triangle, (v &&& 0x04) != 0),
        noise: enable(apu.noise, (v &&& 0x08) != 0)
    }
  end

  defp enable(ch, true), do: %{ch | enabled: true}
  defp enable(ch, false), do: %{ch | enabled: false, length: 0}

  defp frame_write(apu, v) do
    mode = if (v &&& 0x80) != 0, do: 5, else: 4
    apu = %{apu | frame_mode: mode, irq_inhibit: (v &&& 0x40) != 0, seq_cycle: 0}
    apu = if apu.irq_inhibit, do: %{apu | frame_irq: false}, else: apu
    # 5-step mode immediately clocks a quarter + half frame.
    if mode == 5, do: half_frame(quarter_frame(apu)), else: apu
  end

  # Bulk-run only once ~a scanline of cycles has accrued; keeps frame-IRQ / status
  # latency under a scanline while amortising the run over many CPU cycles.
  @flush_threshold 100

  @doc """
  Advance the APU by `n` CPU cycles, emitting samples at 44.1kHz.

  Cycles are accrued and run in bulk. The bulk `run/2` splits the span into
  segments that each end on the next event that can change the output — a
  frame-sequencer step (240Hz), the MMC5 240Hz step, or a 44.1kHz sample point.
  Between those only the channel timers move, so they advance in closed form
  (`advance_counter/3`) while envelope/length/sweep stay constant. This turns
  ~1.79M per-cycle struct passes/second into a few thousand, same output.

  Anything that observes APU state (register writes, `$4015`, sample drain) runs
  the backlog first via `flush/1`; `irq?/1` reads the (≤1 scanline stale) flag
  directly so it stays cheap on the per-instruction interrupt poll.
  """
  def tick(apu, n) when apu.pending + n >= @flush_threshold do
    run(%{apu | pending: 0}, apu.pending + n)
  end

  def tick(apu, n), do: %{apu | pending: apu.pending + n}

  @doc "Run any accrued cycles so the APU state is current."
  def flush(%__MODULE__{pending: 0} = apu), do: apu
  def flush(%__MODULE__{pending: p} = apu), do: run(%{apu | pending: 0}, p)

  defp run(apu, 0), do: apu

  defp run(%{m5_active: true} = apu, n) do
    dc = min(n, min(to_sample(apu), min(to_frame(apu), to_m5(apu))))
    run(advance(apu, dc), n - dc)
  end

  # Non-MMC5 (the common case): no MMC5 sequencer boundary to segment on.
  defp run(apu, n) do
    dc = min(n, min(to_sample(apu), to_frame(apu)))
    run(advance(apu, dc), n - dc)
  end

  # Cycles until the next 44.1kHz sample point (always ≥ 1).
  defp to_sample(apu), do: max(1, ceil((1.0 - apu.sample_acc) / @rate_ratio))

  # Cycles until the next frame-sequencer boundary (steps + the sequence wrap).
  defp to_frame(%{seq_cycle: sc}) when sc < 7457, do: 7457 - sc
  defp to_frame(%{seq_cycle: sc}) when sc < 14913, do: 14913 - sc
  defp to_frame(%{seq_cycle: sc}) when sc < 22371, do: 22371 - sc
  defp to_frame(%{frame_mode: 5, seq_cycle: sc}) when sc < 37281, do: 37281 - sc
  defp to_frame(%{frame_mode: 5, seq_cycle: sc}), do: 37282 - sc
  defp to_frame(%{seq_cycle: sc}) when sc < 29829, do: 29829 - sc
  defp to_frame(%{seq_cycle: sc}), do: 29830 - sc

  # Cycles until the MMC5 240Hz step.
  defp to_m5(apu), do: 7457 - apu.m5seq

  # Advance `dc` CPU cycles: move every channel's timer/sequence in closed form,
  # bump the sequencer/sample accumulators, then fire whatever landed at the end.
  defp advance(apu, dc) do
    clocks = div(dc + if(apu.apu_tick, do: 1, else: 0), 2)
    {p1t, p1s} = adv_pulse(apu.p1_timer, apu.p1_seq, apu.pulse1.period, clocks)
    {p2t, p2s} = adv_pulse(apu.p2_timer, apu.p2_seq, apu.pulse2.period, clocks)
    {tt, ts} = adv_triangle(apu.tri_timer, apu.tri_seq, apu.triangle, dc)

    {nt, ns} =
      adv_noise(apu.noise_timer, apu.noise_shift, apu.noise.period, apu.noise.mode, clocks)

    %{
      apu
      | p1_timer: p1t,
        p1_seq: p1s,
        p2_timer: p2t,
        p2_seq: p2s,
        tri_timer: tt,
        tri_seq: ts,
        noise_timer: nt,
        noise_shift: ns,
        seq_cycle: apu.seq_cycle + dc,
        sample_acc: apu.sample_acc + dc * @rate_ratio,
        apu_tick: apu.apu_tick != (rem(dc, 2) == 1)
    }
    |> frame_action()
    |> advance_mmc5(clocks, dc)
    |> emit_sample()
  end

  # MMC5 sound channels + 240Hz sequencer — only for games that use them.
  defp advance_mmc5(%{m5_active: false} = apu, _clocks, _dc), do: apu

  defp advance_mmc5(apu, clocks, dc) do
    {m1t, m1s} = adv_pulse(apu.m5p1_timer, apu.m5p1_seq, apu.m5p1.period, clocks)
    {m2t, m2s} = adv_pulse(apu.m5p2_timer, apu.m5p2_seq, apu.m5p2.period, clocks)

    %{apu | m5p1_timer: m1t, m5p1_seq: m1s, m5p2_timer: m2t, m5p2_seq: m2s, m5seq: apu.m5seq + dc}
    |> mmc5_action()
  end

  # Down-counter over `e` clocks: returns {remaining timer, sequence steps}. The
  # counter runs period..0 then reloads period, so a full cycle is period+1 clocks.
  defp advance_counter(timer, _period, e) when e <= timer, do: {timer - e, 0}

  defp advance_counter(timer, period, e) do
    r = e - timer - 1
    {period - rem(r, period + 1), 1 + div(r, period + 1)}
  end

  # Triangle clocks at the full CPU rate; its sequence only advances while the
  # linear and length counters are non-zero (the timer reloads either way).
  #
  # A period below 2 means an ultrasonic frequency (>27kHz) games use to silence
  # the triangle; it's inaudible on hardware but, point-sampled at 44.1kHz, would
  # alias down to an audible squeal (period 0 → 55930Hz → 11830Hz). Freeze the
  # sequencer there so the output holds steady and the DC-blocking high-pass
  # flattens it to silence, matching perceived hardware behaviour.
  defp adv_triangle(timer, seq, t, e) do
    {timer2, steps} = advance_counter(timer, t.period, e)
    advancing = t.linear > 0 and t.length > 0 and t.period >= 2
    {timer2, if(advancing, do: seq + steps &&& 0x1F, else: seq)}
  end

  # Pulse (2A03 and MMC5) clocks at CPU/2; `e` is already the CPU/2 clock count.
  defp adv_pulse(timer, seq, _period, 0), do: {timer, seq}

  defp adv_pulse(timer, seq, period, e) do
    {timer2, steps} = advance_counter(timer, period, e)
    {timer2, seq + steps &&& 0x07}
  end

  # Noise clocks at CPU/2; each timer wrap steps the 15-bit LFSR once.
  defp adv_noise(timer, shift, _period, _mode, 0), do: {timer, shift}

  defp adv_noise(timer, shift, period, mode, e) do
    {timer2, steps} = advance_counter(timer, period, e)
    {timer2, lfsr(shift, mode, steps)}
  end

  defp lfsr(shift, _mode, 0), do: shift

  defp lfsr(shift, mode, steps) do
    fb = bxor(shift, shift >>> if(mode, do: 6, else: 1)) &&& 1
    lfsr(shift >>> 1 ||| fb <<< 14, mode, steps - 1)
  end

  defp mmc5_frame(ch), do: ch |> clock_env() |> clock_length()

  # MMC5 240Hz step (envelope + length on both MMC5 pulses; length at 2x rate).
  defp mmc5_action(%{m5seq: m} = apu) when m >= 7457 do
    %{apu | m5seq: 0, m5p1: mmc5_frame(apu.m5p1), m5p2: mmc5_frame(apu.m5p2)}
  end

  defp mmc5_action(apu), do: apu

  defp emit_sample(%{sample_acc: acc} = apu) when acc >= 1.0 do
    {apu, y} = filter(apu, mix(apu))
    %{apu | sample_acc: acc - 1.0, samples: [clamp(round(y * 32767)) | apu.samples]}
  end

  defp emit_sample(apu), do: apu

  # Frame sequencer: ~240Hz steps drive envelopes/linear (quarter) and
  # length/sweep (half), with an IRQ at the end of a 4-step sequence. Called once
  # `seq_cycle` has been advanced onto a boundary; a no-op otherwise.
  defp frame_action(%{frame_mode: 5, seq_cycle: sc} = apu), do: frame_at(apu, sc, @frame5, 37282)
  defp frame_action(%{seq_cycle: sc} = apu), do: frame_at(apu, sc, @frame4, 29830)

  defp frame_at(apu, sc, steps, _wrap) when sc == elem(steps, 0) do
    quarter_frame(apu)
  end

  defp frame_at(apu, sc, steps, _wrap) when sc == elem(steps, 1) do
    half_frame(quarter_frame(apu))
  end

  defp frame_at(apu, sc, steps, _wrap) when sc == elem(steps, 2) do
    quarter_frame(apu)
  end

  defp frame_at(%{frame_mode: 5} = apu, sc, steps, _wrap) when sc == elem(steps, 3) do
    half_frame(quarter_frame(apu))
  end

  defp frame_at(apu, sc, steps, _wrap) when sc == elem(steps, 3) do
    %{half_frame(quarter_frame(apu)) | frame_irq: not apu.irq_inhibit}
  end

  defp frame_at(apu, sc, _steps, wrap) when sc >= wrap, do: %{apu | seq_cycle: 0}
  defp frame_at(apu, _sc, _steps, _wrap), do: apu

  defp quarter_frame(apu) do
    %{
      apu
      | pulse1: clock_env(apu.pulse1),
        pulse2: clock_env(apu.pulse2),
        noise: clock_env(apu.noise),
        triangle: clock_linear(apu.triangle)
    }
  end

  defp half_frame(apu) do
    %{
      apu
      | pulse1: apu.pulse1 |> clock_length() |> clock_sweep(),
        pulse2: apu.pulse2 |> clock_length() |> clock_sweep(),
        triangle: clock_length(apu.triangle),
        noise: clock_length(apu.noise)
    }
  end

  defp clock_env(%{env_start: true} = ch) do
    %{ch | env_start: false, env_decay: 15, env_div: ch.vol}
  end

  defp clock_env(%{env_div: 0} = ch) do
    decay =
      cond do
        ch.env_decay > 0 -> ch.env_decay - 1
        ch.halt -> 15
        true -> 0
      end

    %{ch | env_div: ch.vol, env_decay: decay}
  end

  defp clock_env(ch), do: %{ch | env_div: ch.env_div - 1}

  defp clock_length(%{halt: false, length: l} = ch) when l > 0, do: %{ch | length: l - 1}
  defp clock_length(ch), do: ch

  defp clock_linear(t) do
    linear =
      cond do
        t.reload_flag -> t.linear_reload
        t.linear > 0 -> t.linear - 1
        true -> 0
      end

    %{t | linear: linear, reload_flag: t.reload_flag and t.control}
  end

  defp clock_sweep(p) do
    target = sweep_target(p)

    p =
      if p.sweep_div == 0 and p.sweep_en and p.sweep_shift > 0 and not sweep_mute?(p),
        do: %{p | period: target},
        else: p

    if p.sweep_div == 0 or p.sweep_reload,
      do: %{p | sweep_div: p.sweep_period, sweep_reload: false},
      else: %{p | sweep_div: p.sweep_div - 1}
  end

  defp sweep_target(p) do
    change = p.period >>> p.sweep_shift

    if p.sweep_neg,
      do: max(p.period - change - if(p.ones, do: 0, else: 1), 0),
      else: p.period + change
  end

  defp sweep_mute?(p), do: p.period < 8 or sweep_target(p) > 0x7FF

  # --- output + mixing ---

  defp pulse_level(%{length: 0}, _seq), do: 0

  defp pulse_level(p, seq) do
    cond do
      sweep_mute?(p) -> 0
      (elem(@duty, p.duty) >>> (7 - seq) &&& 1) == 0 -> 0
      p.const -> p.vol
      true -> p.env_decay
    end
  end

  defp tri_level(seq), do: elem(@tri_seq, seq)

  defp noise_level(%{length: 0}, _shift), do: 0
  defp noise_level(_, shift) when (shift &&& 1) == 1, do: 0
  defp noise_level(%{vol: vol, const: const}, _shift) when not is_nil(const), do: vol
  defp noise_level(%{env_decay: decay}, _shift), do: decay

  # Precomputed nonlinear mixer tables (NESdev "Lookup Table"): pulse index is
  # pulse1+pulse2 (0..30); tnd index is 3*triangle + 2*noise + dmc (0..202).
  # Numerators are the range-preserving approximations for the combined index.
  @pulse_table List.to_tuple(
                 for n <- 0..30, do: if(n == 0, do: 0.0, else: 95.52 / (8128.0 / n + 100))
               )
  @tnd_table List.to_tuple(
               for n <- 0..202, do: if(n == 0, do: 0.0, else: 163.67 / (24329.0 / n + 100))
             )
  # MMC5 mixer contributions, precomputed to avoid a per-sample float division +
  # scale (CV3 uses MMC5 audio, so mmc5_out/1 runs ~744x/frame). Same values as
  # the inline formulas → byte-identical output. Pulse pair index 0..30; raw PCM
  # ($5011) index 0..255.
  @m5_pulse_table List.to_tuple(
                    for n <- 0..30, do: if(n == 0, do: 0.0, else: 95.88 / (8128 / n + 100))
                  )
  @m5pcm_table List.to_tuple(for n <- 0..255, do: n / 255 * 0.25)

  # Nonlinear mixer → unipolar 0..~1.0 float via table lookup. The RCA output
  # filters (filter/2) remove the DC offset and band-limit before scaling to PCM
  # in emit_sample/1.
  defp mix(apu) do
    pulse_out =
      elem(
        @pulse_table,
        pulse_level(apu.pulse1, apu.p1_seq) + pulse_level(apu.pulse2, apu.p2_seq)
      )

    tnd_out =
      elem(@tnd_table, 3 * tri_level(apu.tri_seq) + 2 * noise_level(apu.noise, apu.noise_shift))

    pulse_out + tnd_out + mmc5_out(apu)
  end

  # NES RCA output circuit: a DC-blocking first-order high-pass (90Hz) then a
  # first-order low-pass, applied per 44.1kHz sample. The low-pass sits at 8kHz
  # rather than the hardware's ~14kHz to attenuate the triangle's 32-step DAC
  # "zipper" (32x the note pitch, 6-12kHz), which is authentic but reads as a
  # squeal without the analog slew-limiting real hardware applies. The 440Hz
  # high-pass the wiki lists is omitted: it guts the bass fundamental and makes
  # that zipper dominate. Coefficients: a = RC/(RC+dt) for the high-pass,
  # alpha = dt/(RC+dt) for the low-pass, with dt = 1/44100 and RC = 1/(2*pi*fc).
  @hp90 0.987340
  @lp8k 0.532680

  defp filter(apu, x) do
    hp = @hp90 * (apu.f_hp + x - apu.f_hp_x)
    lp = apu.f_lp + @lp8k * (hp - apu.f_lp)

    {%{apu | f_hp: hp, f_hp_x: x, f_lp: lp}, lp}
  end

  # MMC5 sound sums with the 2A03 output (exact blend unspecified; approximated
  # with the pulse curve + linear PCM).
  defp mmc5_out(%{m5_active: false}), do: 0.0

  defp mmc5_out(apu) do
    m5 = m5_pulse_level(apu.m5p1, apu.m5p1_seq) + m5_pulse_level(apu.m5p2, apu.m5p2_seq)
    elem(@m5_pulse_table, m5) + elem(@m5pcm_table, apu.m5pcm)
  end

  # Like a 2A03 pulse but with no sweep unit (never muted for period < 8).
  defp m5_pulse_level(%{length: 0}, _seq), do: 0
  defp m5_pulse_level(%{duty: duty}, seq) when (elem(@duty, duty) >>> (7 - seq) &&& 1) == 0, do: 0
  defp m5_pulse_level(%{const: const, vol: vol}, _seq) when not is_nil(const), do: vol
  defp m5_pulse_level(%{env_decay: decay}, _seq), do: decay

  defp clamp(v) when v > 32767, do: 32767
  defp clamp(v) when v < -32768, do: -32768
  defp clamp(v), do: v
end
