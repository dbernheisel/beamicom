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

  @compile {:inline, bool: 2, clamp: 1, tri_level: 1, clock_length: 1, sweep_target: 1}

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
            cycle: 0,
            seq_cycle: 0,
            apu_tick: false,
            sample_acc: 0.0,
            samples: [],
            # MMC5 sound: two sweep-less pulses + raw PCM, own 240Hz sequencer.
            m5p1: nil,
            m5p2: nil,
            m5pcm: 0,
            m5seq: 0

  defp pulse,
    do: %{
      duty: 0,
      seq: 0,
      timer: 0,
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

  defp tri,
    do: %{
      timer: 0,
      period: 0,
      seq: 0,
      length: 0,
      halt: false,
      control: false,
      linear: 0,
      linear_reload: 0,
      reload_flag: false,
      enabled: false
    }

  defp noise,
    do: %{
      timer: 0,
      period: 0,
      shift: 1,
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

  def new,
    do: %__MODULE__{
      pulse1: pulse(),
      pulse2: %{pulse() | ones: true},
      triangle: tri(),
      noise: noise(),
      m5p1: pulse(),
      m5p2: pulse()
    }

  @doc "MMC5 sound register write ($5000-$5015)."
  def mmc5_write(apu, addr, val) do
    case addr do
      a when a in 0x5000..0x5003 ->
        %{apu | m5p1: pulse_reg(apu.m5p1, a - 0x5000, val)}

      a when a in 0x5004..0x5007 ->
        %{apu | m5p2: pulse_reg(apu.m5p2, a - 0x5004, val)}

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
  def take_samples(%__MODULE__{samples: s} = apu), do: {Enum.reverse(s), %{apu | samples: []}}

  # --- register writes ($4000-$4017) ---

  def write(apu, addr, val) when addr in 0x4000..0x4003,
    do: %{apu | pulse1: pulse_reg(apu.pulse1, addr - 0x4000, val)}

  def write(apu, addr, val) when addr in 0x4004..0x4007,
    do: %{apu | pulse2: pulse_reg(apu.pulse2, addr - 0x4004, val)}

  def write(apu, addr, val) when addr in 0x4008..0x400B,
    do: %{apu | triangle: tri_reg(apu.triangle, addr - 0x4008, val)}

  def write(apu, addr, val) when addr in 0x400C..0x400F,
    do: %{apu | noise: noise_reg(apu.noise, addr - 0x400C, val)}

  def write(apu, 0x4015, val), do: status_write(apu, val)
  def write(apu, 0x4017, val), do: frame_write(apu, val)
  def write(apu, _addr, _val), do: apu

  @doc "Read $4015 status: length-counter-active flags + frame IRQ (clears the IRQ)."
  def read_status(apu) do
    b =
      bool(apu.pulse1.length > 0, 0x01) ||| bool(apu.pulse2.length > 0, 0x02) |||
        bool(apu.triangle.length > 0, 0x04) ||| bool(apu.noise.length > 0, 0x08) |||
        bool(apu.frame_irq, 0x40)

    {b, %{apu | frame_irq: false}}
  end

  defp bool(true, mask), do: mask
  defp bool(false, _mask), do: 0

  defp pulse_reg(p, 0, v),
    do: %{p | duty: v >>> 6, halt: (v &&& 0x20) != 0, const: (v &&& 0x10) != 0, vol: v &&& 0x0F}

  defp pulse_reg(p, 1, v),
    do: %{
      p
      | sweep_en: (v &&& 0x80) != 0,
        sweep_period: v >>> 4 &&& 0x07,
        sweep_neg: (v &&& 0x08) != 0,
        sweep_shift: v &&& 0x07,
        sweep_reload: true
    }

  defp pulse_reg(p, 2, v), do: %{p | period: (p.period &&& 0x700) ||| v}

  defp pulse_reg(p, 3, v) do
    period = (p.period &&& 0xFF) ||| (v &&& 0x07) <<< 8
    length = if p.enabled, do: elem(@length, v >>> 3), else: p.length
    %{p | period: period, length: length, seq: 0, env_start: true}
  end

  defp tri_reg(t, 0, v),
    do: %{t | control: (v &&& 0x80) != 0, halt: (v &&& 0x80) != 0, linear_reload: v &&& 0x7F}

  defp tri_reg(t, 2, v), do: %{t | period: (t.period &&& 0x700) ||| v}

  defp tri_reg(t, 3, v) do
    length = if t.enabled, do: elem(@length, v >>> 3), else: t.length
    %{t | period: (t.period &&& 0xFF) ||| (v &&& 0x07) <<< 8, length: length, reload_flag: true}
  end

  defp tri_reg(t, _, _), do: t

  defp noise_reg(n, 0, v),
    do: %{n | halt: (v &&& 0x20) != 0, const: (v &&& 0x10) != 0, vol: v &&& 0x0F}

  defp noise_reg(n, 2, v),
    do: %{n | mode: (v &&& 0x80) != 0, period: elem(@noise_periods, v &&& 0x0F)}

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

  # --- clocking ---

  @doc "Advance the APU by `n` CPU cycles, emitting samples at 44.1kHz."
  def tick(apu, 0), do: apu
  def tick(apu, n), do: tick(cycle(apu), n - 1)

  defp cycle(apu) do
    apu = clock_triangle_timer(apu)
    tick? = apu.apu_tick

    apu =
      if tick?,
        do: %{clock_apu_timers(apu) | m5p1: clock_pulse(apu.m5p1), m5p2: clock_pulse(apu.m5p2)},
        else: apu

    sc = apu.seq_cycle + 1
    m5s = apu.m5seq

    # Common cycle: no frame-sequencer step and no MMC5 240Hz step. Bump the two
    # counters + the toggle in a single struct pass and only fold in a sample.
    if seq_step?(apu.frame_mode, sc) or m5s >= 7457 do
      %{apu | apu_tick: not tick?}
      |> frame_sequencer()
      |> mmc5_sequencer()
      |> sample()
    else
      acc = apu.sample_acc + @rate_ratio

      apu = %{apu | apu_tick: not tick?, seq_cycle: sc, m5seq: m5s + 1, sample_acc: acc}

      if acc >= 1.0,
        do: %{apu | sample_acc: acc - 1.0, samples: [mix(apu) | apu.samples]},
        else: apu
    end
  end

  # Does CPU-cycle `sc` land on a 4-/5-step frame-sequencer boundary (or the wrap)?
  defp seq_step?(5, sc), do: sc == 7457 or sc == 14913 or sc == 22371 or sc >= 37281
  defp seq_step?(_mode, sc), do: sc == 7457 or sc == 14913 or sc == 22371 or sc >= 29829

  # MMC5 sound has its own 240Hz sequencer (~7457 CPU cycles) clocking envelope
  # and length every step (length runs at twice the 2A03 rate).
  defp mmc5_sequencer(apu) do
    if apu.m5seq >= 7457 do
      %{apu | m5seq: 0, m5p1: mmc5_frame(apu.m5p1), m5p2: mmc5_frame(apu.m5p2)}
    else
      %{apu | m5seq: apu.m5seq + 1}
    end
  end

  defp mmc5_frame(ch), do: ch |> clock_env() |> clock_length()

  # Triangle timer runs at the full CPU rate; the others at CPU/2.
  defp clock_triangle_timer(apu), do: %{apu | triangle: clock_triangle(apu.triangle)}

  defp clock_triangle(%{timer: timer} = t) when timer > 0, do: %{t | timer: timer - 1}

  defp clock_triangle(%{linear: linear, length: length} = t) when linear > 0 and length > 0,
    do: %{t | timer: t.period, seq: t.seq + 1 &&& 0x1F}

  defp clock_triangle(t), do: %{t | timer: t.period}

  defp clock_apu_timers(apu),
    do: %{
      apu
      | pulse1: clock_pulse(apu.pulse1),
        pulse2: clock_pulse(apu.pulse2),
        noise: clock_noise(apu.noise)
    }

  defp clock_pulse(p) do
    if p.timer > 0,
      do: %{p | timer: p.timer - 1},
      else: %{p | timer: p.period, seq: p.seq + 1 &&& 0x07}
  end

  defp clock_noise(n) do
    if n.timer > 0 do
      %{n | timer: n.timer - 1}
    else
      fb = bxor(n.shift, n.shift >>> if(n.mode, do: 6, else: 1)) &&& 1
      %{n | timer: n.period, shift: n.shift >>> 1 ||| fb <<< 14}
    end
  end

  # Frame sequencer: steps at ~240Hz drive envelopes/linear (quarter) and
  # length/sweep (half), with an IRQ at the end of a 4-step sequence.
  defp frame_sequencer(apu) do
    steps = if apu.frame_mode == 5, do: @frame5, else: @frame4
    wrap = if apu.frame_mode == 5, do: 37282, else: 29830
    sc = apu.seq_cycle + 1
    apu = %{apu | seq_cycle: sc}

    cond do
      sc == elem(steps, 0) -> quarter_frame(apu)
      sc == elem(steps, 1) -> half_frame(quarter_frame(apu))
      sc == elem(steps, 2) -> quarter_frame(apu)
      sc == elem(steps, 3) and apu.frame_mode == 5 -> half_frame(quarter_frame(apu))
      sc == elem(steps, 3) -> %{half_frame(quarter_frame(apu)) | frame_irq: not apu.irq_inhibit}
      sc >= wrap -> %{apu | seq_cycle: 0}
      true -> apu
    end
  end

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

  defp clock_env(%{env_start: true} = ch),
    do: %{ch | env_start: false, env_decay: 15, env_div: ch.vol}

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

  defp sample(apu) do
    acc = apu.sample_acc + @sample_rate / @cpu_hz

    if acc >= 1.0 do
      %{apu | sample_acc: acc - 1.0, samples: [mix(apu) | apu.samples]}
    else
      %{apu | sample_acc: acc}
    end
  end

  defp pulse_level(p) do
    cond do
      p.length == 0 -> 0
      sweep_mute?(p) -> 0
      (elem(@duty, p.duty) >>> (7 - p.seq) &&& 1) == 0 -> 0
      p.const -> p.vol
      true -> p.env_decay
    end
  end

  defp tri_level(t), do: elem(@tri_seq, t.seq)

  defp noise_level(n) do
    cond do
      n.length == 0 -> 0
      (n.shift &&& 1) == 1 -> 0
      n.const -> n.vol
      true -> n.env_decay
    end
  end

  # Nonlinear mixer → signed 16-bit PCM.
  defp mix(apu) do
    p = pulse_level(apu.pulse1) + pulse_level(apu.pulse2)
    pulse_out = if p == 0, do: 0.0, else: 95.88 / (8128 / p + 100)
    tnd = tri_level(apu.triangle) / 8227 + noise_level(apu.noise) / 12241
    tnd_out = if tnd == 0, do: 0.0, else: 159.79 / (1 / tnd + 100)
    # NES output is unipolar 0..~1.0; scale to positive 16-bit PCM.
    clamp(round((pulse_out + tnd_out + mmc5_out(apu)) * 32767))
  end

  # MMC5 sound sums with the 2A03 output (exact blend unspecified; approximated
  # with the pulse curve + linear PCM).
  defp mmc5_out(apu) do
    m5 = m5_pulse_level(apu.m5p1) + m5_pulse_level(apu.m5p2)
    pulses = if m5 == 0, do: 0.0, else: 95.88 / (8128 / m5 + 100)
    pulses + apu.m5pcm / 255 * 0.25
  end

  # Like a 2A03 pulse but with no sweep unit (never muted for period < 8).
  defp m5_pulse_level(p) do
    cond do
      p.length == 0 -> 0
      (elem(@duty, p.duty) >>> (7 - p.seq) &&& 1) == 0 -> 0
      p.const -> p.vol
      true -> p.env_decay
    end
  end

  defp clamp(v) when v > 32767, do: 32767
  defp clamp(v) when v < 0, do: 0
  defp clamp(v), do: v
end
