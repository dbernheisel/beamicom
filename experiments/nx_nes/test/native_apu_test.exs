defmodule NxNes.NativeAPUTest do
  use ExUnit.Case, async: false
  alias NxNes.NativeAPU, as: Native

  test "native continuous state/PCM match across sequencer, noise, sweep and buffer boundaries" do
    base = Beamicom.NES.APU.new()

    p = %{
      base.pulse1
      | length: 20,
        period: 37,
        vol: 9,
        env_decay: 8,
        env_start: true,
        duty: 2,
        sweep_en: true,
        sweep_shift: 2,
        sweep_period: 2
    }

    for mode <- [4, 5],
        noise <- [false, true],
        active <- [false, true],
        sc <- [0, 7456, 14912, 22370, if(mode == 5, do: 37280, else: 29828)] do
      seed = %{
        base
        | frame_mode: mode,
          seq_cycle: sc,
          m5seq: 7456,
          m5_active: active,
          pulse1: p,
          pulse2: %{p | ones: true, sweep_neg: true},
          m5p1: p,
          m5p2: %{p | duty: 3},
          triangle: %{
            base.triangle
            | length: 10,
              linear: 8,
              linear_reload: 5,
              period: 27,
              reload_flag: true
          },
          noise: %{base.noise | length: 5, period: 0, mode: noise, vol: 6, env_start: true},
          sample_acc: 0.99,
          m5pcm: 90,
          f_hp: 0.2,
          f_hp_x: 0.1,
          f_lp: 0.15
      }

      packed = Native.pack(seed)
      assert Native.unpack(packed) == seed

      Enum.reduce([0, 1, 100, 7457, 29830, 100_000], {seed, packed}, fn cycles, {ref, state} ->
        {next, pcm, left} = Native.run(state, cycles)
        assert left >= 0
        if cycles == 100_000, do: assert(byte_size(pcm) == 2048 and left > 0)
        expected = NxNes.ReferenceAPU.run(ref, cycles - left)
        {_, expected_pcm, expected} = Beamicom.NES.APU.take_pcm(expected)
        assert pcm == expected_pcm
        assert_state(Native.unpack(next), expected)
        {expected, next}
      end)

      # The input binary remains a reusable checkpoint.
      assert Native.unpack(packed) == seed
    end
  end

  test "invalid native arguments fail safely" do
    s = Native.pack(Beamicom.NES.APU.new())

    for cycles <- [-1, 1_000_001, 0.5] do
      assert_raise ArgumentError, fn -> Native.run(s, cycles) end
    end

    for bytes <- [<<>>, :binary.copy(<<255>>, byte_size(s))] do
      assert_raise ArgumentError, fn -> Native.run(bytes, 1) end
    end

    for bad <- [
          %{Beamicom.NES.APU.new() | m5pcm: 256},
          %{Beamicom.NES.APU.new() | sample_acc: -1.0}
        ] do
      assert_raise ArgumentError, fn -> Native.run(Native.pack(bad), 1) end
    end

    assert_raise ArgumentError, fn ->
      apply(Native, :pack, [%{Beamicom.NES.APU.new() | dmc: %{}}])
    end
  end

  defp assert_state(actual, expected) do
    for {k, v} <- Native.fields(expected) do
      a = Map.fetch!(actual, k)

      cond do
        is_struct(v) -> assert_state(a, v)
        is_float(v) -> assert_in_delta a, v, 1.0e-12
        true -> assert a == v, "#{k}: #{inspect(a)} != #{inspect(v)}"
      end
    end
  end
end
