defmodule Beamicom.NES.Nx.APUWrites do
  @moduledoc "Tensor register writes for block audio; -1 at $4015 represents a status read."
  import Nx.Defn

  @length [
    10,
    254,
    20,
    2,
    40,
    4,
    80,
    6,
    160,
    8,
    60,
    10,
    14,
    12,
    26,
    14,
    12,
    16,
    24,
    18,
    48,
    20,
    96,
    22,
    192,
    24,
    72,
    26,
    16,
    28,
    32,
    30
  ]
  @noise [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]
  defn apply(s, addr, v) do
    p1_write = addr >= 0x4000 and addr <= 0x4003
    p2_write = addr >= 0x4004 and addr <= 0x4007
    triangle_write = addr >= 0x4008 and addr <= 0x400B
    noise_write = addr >= 0x400C and addr <= 0x400F
    status_read = addr == 0x4015 and v == -1
    status_write = addr == 0x4015 and v != -1
    frame_write = addr == 0x4017
    m5_write = addr >= 0x5000 and addr <= 0x5015

    p1 = %{
      s
      | pulse1: pulse(s.pulse1, addr - 0x4000, v),
        p1_seq: Nx.select(addr == 0x4003, 0, s.p1_seq)
    }

    p2 = %{
      s
      | pulse2: pulse(s.pulse2, addr - 0x4004, v),
        p2_seq: Nx.select(addr == 0x4007, 0, s.p2_seq)
    }

    triangle = %{s | triangle: triangle(s.triangle, addr - 0x4008, v)}
    noise = %{s | noise: noise(s.noise, addr - 0x400C, v)}
    read_status = %{s | frame_irq: Nx.tensor(0, type: :s32)}

    write_status = %{
      s
      | pulse1: enable(s.pulse1, band(v, 1)),
        pulse2: enable(s.pulse2, band(v, 2)),
        triangle: enable(s.triangle, band(v, 4)),
        noise: enable(s.noise, band(v, 8)),
        dmc_irq: Nx.tensor(0, type: :s32)
    }

    frame = %{
      s
      | frame_mode: Nx.select(band(v, 128) != 0, 5, 4),
        irq_inhibit: int(band(v, 64) != 0),
        seq_cycle: Nx.tensor(0, type: :s32),
        frame_irq: Nx.select(band(v, 64) != 0, 0, s.frame_irq)
    }

    frame_clocked = Beamicom.NES.Nx.APU.frame(%{frame | seq_cycle: Nx.tensor(14913, type: :s32)})
    frame_clocked = %{frame_clocked | seq_cycle: Nx.tensor(0, type: :s32)}
    frame = select_state(frame, frame.frame_mode == 5, frame_clocked)

    m5_p1 = addr >= 0x5000 and addr <= 0x5003
    m5_p2 = addr >= 0x5004 and addr <= 0x5007

    m5 = %{
      s
      | m5_active: Nx.tensor(1, type: :s32),
        m5p1: select_state(s.m5p1, m5_p1, pulse(s.m5p1, addr - 0x5000, v)),
        m5p2: select_state(s.m5p2, m5_p2, pulse(s.m5p2, addr - 0x5004, v)),
        m5p1_seq: Nx.select(addr == 0x5003, 0, s.m5p1_seq),
        m5p2_seq: Nx.select(addr == 0x5007, 0, s.m5p2_seq),
        m5pcm: Nx.select(addr == 0x5011, v, s.m5pcm)
    }

    # $5015 is the only non-pulse MMC5 write that changes channel enable state.
    m5 = %{
      m5
      | m5p1: select_state(m5.m5p1, addr == 0x5015, enable(s.m5p1, band(v, 1))),
        m5p2: select_state(m5.m5p2, addr == 0x5015, enable(s.m5p2, band(v, 2)))
    }

    s
    |> select_state(p1_write, p1)
    |> select_state(p2_write, p2)
    |> select_state(triangle_write, triangle)
    |> select_state(noise_write, noise)
    |> select_state(status_read, read_status)
    |> select_state(status_write, write_status)
    |> select_state(frame_write, frame)
    |> select_state(m5_write, m5)
  end

  defnp pulse(p, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)

    %{
      p
      | duty: Nx.select(reg == 0, shr(v, 6), p.duty),
        halt: Nx.select(reg == 0, int(band(v, 32) != 0), p.halt),
        const: Nx.select(reg == 0, int(band(v, 16) != 0), p.const),
        vol: Nx.select(reg == 0, band(v, 15), p.vol),
        sweep_en: Nx.select(reg == 1, int(band(v, 128) != 0), p.sweep_en),
        sweep_period: Nx.select(reg == 1, band(shr(v, 4), 7), p.sweep_period),
        sweep_neg: Nx.select(reg == 1, int(band(v, 8) != 0), p.sweep_neg),
        sweep_shift: Nx.select(reg == 1, band(v, 7), p.sweep_shift),
        sweep_reload: Nx.select(reg == 1, 1, p.sweep_reload),
        period:
          Nx.select(
            reg == 2,
            Nx.bitwise_or(band(p.period, 0x700), v),
            Nx.select(
              reg == 3,
              Nx.bitwise_or(band(p.period, 255), Nx.left_shift(band(v, 7), 8)),
              p.period
            )
          ),
        length: Nx.select(reg == 3 and p.enabled != 0, lengths[shr(v, 3)], p.length),
        env_start: Nx.select(reg == 3, 1, p.env_start)
    }
  end

  defnp triangle(t, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)

    %{
      t
      | control: Nx.select(reg == 0, int(band(v, 128) != 0), t.control),
        halt: Nx.select(reg == 0, int(band(v, 128) != 0), t.halt),
        linear_reload: Nx.select(reg == 0, band(v, 127), t.linear_reload),
        period:
          Nx.select(
            reg == 2,
            Nx.bitwise_or(band(t.period, 0x700), v),
            Nx.select(
              reg == 3,
              Nx.bitwise_or(band(t.period, 255), Nx.left_shift(band(v, 7), 8)),
              t.period
            )
          ),
        length: Nx.select(reg == 3 and t.enabled != 0, lengths[shr(v, 3)], t.length),
        reload_flag: Nx.select(reg == 3, 1, t.reload_flag)
    }
  end

  defnp noise(n, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)
    periods = Nx.tensor(@noise, type: :s32)

    %{
      n
      | halt: Nx.select(reg == 0, int(band(v, 32) != 0), n.halt),
        const: Nx.select(reg == 0, int(band(v, 16) != 0), n.const),
        vol: Nx.select(reg == 0, band(v, 15), n.vol),
        mode: Nx.select(reg == 2, int(band(v, 128) != 0), n.mode),
        period: Nx.select(reg == 2, periods[band(v, 15)], n.period),
        length: Nx.select(reg == 3 and n.enabled != 0, lengths[shr(v, 3)], n.length),
        env_start: Nx.select(reg == 3, 1, n.env_start)
    }
  end

  deftransformp select_state(state, condition, candidate) do
    Map.new(state, fn {key, value} ->
      replacement = Map.fetch!(candidate, key)

      {key,
       if(is_map(value) and not is_struct(value, Nx.Tensor),
         do: select_state(value, condition, replacement),
         else: Nx.select(condition, replacement, value)
       )}
    end)
  end

  defnp(enable(p, on), do: %{p | enabled: int(on != 0), length: Nx.select(on != 0, p.length, 0)})
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
  defnp(int(x), do: Nx.as_type(x, :s32))
end
