defmodule NxNes.APUWrites do
  @moduledoc "Tensor register writes for the 2A03/MMC5 audio probe; -1 at $4015 represents a status read."
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
    cond do
      addr >= 0x4000 and addr <= 0x4003 ->
        %{
          s
          | pulse1: pulse(s.pulse1, addr - 0x4000, v),
            p1_seq: Nx.select(addr == 0x4003, 0, s.p1_seq)
        }

      addr >= 0x4004 and addr <= 0x4007 ->
        %{
          s
          | pulse2: pulse(s.pulse2, addr - 0x4004, v),
            p2_seq: Nx.select(addr == 0x4007, 0, s.p2_seq)
        }

      addr >= 0x4008 and addr <= 0x400B ->
        %{s | triangle: triangle(s.triangle, addr - 0x4008, v)}

      addr >= 0x400C and addr <= 0x400F ->
        %{s | noise: noise(s.noise, addr - 0x400C, v)}

      addr == 0x4015 and v == -1 ->
        %{s | frame_irq: Nx.tensor(0, type: :s32)}

      addr == 0x4015 ->
        %{
          s
          | pulse1: enable(s.pulse1, band(v, 1)),
            pulse2: enable(s.pulse2, band(v, 2)),
            triangle: enable(s.triangle, band(v, 4)),
            noise: enable(s.noise, band(v, 8)),
            dmc_irq: Nx.tensor(0, type: :s32)
        }

      addr == 0x4017 ->
        s = %{
          s
          | frame_mode: Nx.select(band(v, 128) != 0, 5, 4),
            irq_inhibit: int(band(v, 64) != 0),
            seq_cycle: Nx.tensor(0, type: :s32),
            frame_irq: Nx.select(band(v, 64) != 0, 0, s.frame_irq)
        }

        if s.frame_mode == 5 do
          s = NxNes.APU.frame(%{s | seq_cycle: Nx.tensor(14913, type: :s32)})
          %{s | seq_cycle: Nx.tensor(0, type: :s32)}
        else
          s
        end

      addr >= 0x5000 and addr <= 0x5015 ->
        s = %{s | m5_active: Nx.tensor(1, type: :s32)}

        cond do
          addr <= 0x5003 ->
            %{
              s
              | m5p1: pulse(s.m5p1, addr - 0x5000, v),
                m5p1_seq: Nx.select(addr == 0x5003, 0, s.m5p1_seq)
            }

          addr <= 0x5007 ->
            %{
              s
              | m5p2: pulse(s.m5p2, addr - 0x5004, v),
                m5p2_seq: Nx.select(addr == 0x5007, 0, s.m5p2_seq)
            }

          addr == 0x5011 ->
            %{s | m5pcm: v}

          addr == 0x5015 ->
            %{s | m5p1: enable(s.m5p1, band(v, 1)), m5p2: enable(s.m5p2, band(v, 2))}

          true ->
            s
        end

      true ->
        s
    end
  end

  defnp pulse(p, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)

    cond do
      reg == 0 ->
        %{
          p
          | duty: shr(v, 6),
            halt: int(band(v, 32) != 0),
            const: int(band(v, 16) != 0),
            vol: band(v, 15)
        }

      reg == 1 ->
        %{
          p
          | sweep_en: int(band(v, 128) != 0),
            sweep_period: band(shr(v, 4), 7),
            sweep_neg: int(band(v, 8) != 0),
            sweep_shift: band(v, 7),
            sweep_reload: Nx.tensor(1, type: :s32)
        }

      reg == 2 ->
        %{p | period: Nx.bitwise_or(band(p.period, 0x700), v)}

      true ->
        %{
          p
          | period: Nx.bitwise_or(band(p.period, 255), Nx.left_shift(band(v, 7), 8)),
            length: Nx.select(p.enabled != 0, lengths[shr(v, 3)], p.length),
            env_start: Nx.tensor(1, type: :s32)
        }
    end
  end

  defnp triangle(t, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)

    cond do
      reg == 0 ->
        %{
          t
          | control: int(band(v, 128) != 0),
            halt: int(band(v, 128) != 0),
            linear_reload: band(v, 127)
        }

      reg == 2 ->
        %{t | period: Nx.bitwise_or(band(t.period, 0x700), v)}

      reg == 3 ->
        %{
          t
          | period: Nx.bitwise_or(band(t.period, 255), Nx.left_shift(band(v, 7), 8)),
            length: Nx.select(t.enabled != 0, lengths[shr(v, 3)], t.length),
            reload_flag: Nx.tensor(1, type: :s32)
        }

      true ->
        t
    end
  end

  defnp noise(n, reg, v) do
    lengths = Nx.tensor(@length, type: :s32)
    periods = Nx.tensor(@noise, type: :s32)

    cond do
      reg == 0 ->
        %{n | halt: int(band(v, 32) != 0), const: int(band(v, 16) != 0), vol: band(v, 15)}

      reg == 2 ->
        %{n | mode: int(band(v, 128) != 0), period: periods[band(v, 15)]}

      reg == 3 ->
        %{
          n
          | length: Nx.select(n.enabled != 0, lengths[shr(v, 3)], n.length),
            env_start: Nx.tensor(1, type: :s32)
        }

      true ->
        n
    end
  end

  defnp(enable(p, on), do: %{p | enabled: int(on != 0), length: Nx.select(on != 0, p.length, 0)})
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
  defnp(int(x), do: Nx.as_type(x, :s32))
end
