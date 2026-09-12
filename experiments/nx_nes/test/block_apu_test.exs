defmodule NxNes.BlockAPUTest do
  use ExUnit.Case, async: false
  alias NxNes.{APU, APUWrites, APUReplay, BlockAPU, Batch}

  test "tensor register writes match base/MMC5 channel controls and status reads" do
    fun = EXLA.jit(&APUWrites.apply/3, client: :host)
    s = fixture()

    for addr <- Enum.to_list(0x4000..0x400F) ++ [0x4015, 0x4017] ++ Enum.to_list(0x5000..0x5015),
        v <- if(addr == 0x4015, do: [-1, 0, 15], else: [0, 85, 255]) do
      {expected, _} = APUReplay.reference(s, [{0, addr, v}], 0)

      actual =
        fun.(
          APU.pack(s) |> Batch.resident(),
          Nx.tensor(addr, type: :s32),
          Nx.tensor(v, type: :s32)
        )

      APUReplay.compare!(actual, APU.pack(expected))
    end
  end

  test "blocks preserve writes on sample/sequencer boundaries, same-cycle order, and continuation" do
    fun = EXLA.jit(&BlockAPU.run/4, client: :host)

    for mode <- [4, 5], noise_mode <- [false, true] do
      seed = fixture()
      seed = %{seed | frame_mode: mode, noise: %{seed.noise | mode: noise_mode}}

      entries = [
        {0, 0x5015, 3},
        {0, 0x5000, 0x9F},
        {0, 0x5002, 37},
        {0, 0x5003, 0x08},
        {40, 0x4000, 0x7F},
        {41, 0x4002, 19},
        {7457, 0x4015, -1},
        {7457, 0x5011, 210},
        {14913, 0x4017, 0x80},
        {14913, 0x4003, 0x10},
        {22371, 0x400E, 0x80},
        {29830, 0x5011, 70}
      ]

      Enum.reduce(
        [{entries, 29830}, {[], 29830}, {[{0, 0x4015, 0}, {100, 0x5015, 0}], 1234}],
        {seed, APU.pack(seed) |> Batch.resident()},
        fn {entries, cycles}, {ref, nx} ->
          {events, n} = BlockAPU.events(entries, cycles)
          {s, pcm, count, left, used} = fun.(nx, events, n, Nx.tensor(cycles, type: :s32))
          assert Nx.to_number(left) == 0
          assert Nx.to_number(used) == length(entries)
          {expected, epcm} = APUReplay.reference(ref, entries, cycles)
          assert binary_part(Nx.to_binary(pcm), 0, 2 * Nx.to_number(count)) == epcm
          APUReplay.compare!(s, APU.pack(expected))
          assert %EXLA.Backend{} = s.f_lp.data
          {expected, s}
        end
      )
    end
  end

  test "vector waveform jumps preserve noise states and channel timers" do
    fun = EXLA.jit(&BlockAPU.clock/2, client: :host)

    for mode <- [false, true], shift <- [1, 31, 1023, 32767] do
      seed = fixture()
      seed = %{seed | noise: %{seed.noise | period: 0, mode: mode}, noise_shift: shift}
      offsets = [1, 3, 41, 4096, 7457]
      actual = fun.(APU.pack(seed) |> Batch.resident(), Nx.tensor(offsets, type: :s32))

      for {dc, i} <- Enum.with_index(offsets) do
        expected = NxNes.ReferenceAPU.advance(seed, dc)

        for k <- [
              :p1_timer,
              :p1_seq,
              :p2_timer,
              :p2_seq,
              :tri_timer,
              :tri_seq,
              :noise_timer,
              :noise_shift,
              :seq_cycle,
              :m5seq
            ] do
          assert Nx.to_flat_list(Map.fetch!(actual, k)) |> Enum.at(i) == Map.fetch!(expected, k)
        end
      end
    end
  end

  test "host rejects unsupported DMC and malformed timestamp streams" do
    for entries <- [
          [{2, 0x4000, 1}, {1, 0x4000, 2}],
          [{11, 0x4000, 1}],
          [{0, 0x4010, 0}],
          [{0, 0x4015, 16}],
          [{0, 0x4000, 256}],
          [{0.5, 0x4000, 1}],
          [{0, 0x4000, 1.5}]
        ] do
      assert_raise ArgumentError, fn -> BlockAPU.events(entries, 10) end
    end
  end

  defp fixture do
    s = Beamicom.NES.APU.new()

    p = %{
      s.pulse1
      | enabled: true,
        length: 20,
        period: 37,
        vol: 9,
        env_decay: 8,
        env_start: true,
        duty: 2,
        sweep_en: true,
        sweep_shift: 2,
        sweep_period: 2
    }

    %{
      s
      | pulse1: p,
        pulse2: %{p | ones: true, sweep_neg: true},
        triangle: %{
          s.triangle
          | enabled: true,
            length: 10,
            linear: 8,
            linear_reload: 5,
            period: 27,
            reload_flag: true
        },
        noise: %{s.noise | enabled: true, length: 5, period: 4, vol: 6, env_start: true},
        m5_active: true,
        m5p1: p,
        m5p2: %{p | duty: 3},
        m5pcm: 90,
        f_hp: 0.2,
        f_hp_x: 0.1,
        f_lp: 0.15
    }
  end
end
