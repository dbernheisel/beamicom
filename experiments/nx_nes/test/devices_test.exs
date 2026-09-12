defmodule NxNes.DevicesTest do
  use ExUnit.Case, async: false
  alias NxNes.{APU, PPU, Batch}

  test "MMC5 scanline pixels/status/scroll match with extended attributes, splits and sprite flips" do
    chr = for i <- 0..32767, into: <<>>, do: <<rem(i * 71 + div(i, 16), 256)>>
    rom = Nx.from_binary(chr, :u8) |> Batch.resident()
    base = Beamicom.NES.PPU.new(chr, :vertical)
    vram = for i <- 0..2047, into: <<>>, do: <<rem(i * 13, 256)>>
    exram = Map.new(0..1023, &{&1, rem(&1 * 17, 256)})

    oam =
      for i <- 0..63,
          into: <<>>,
          do: <<if(i < 12, do: 20, else: 255), i, rem(i * 33, 256), rem(i * 7, 256)>>

    fun = EXLA.jit(&PPU.render/2, client: :host)

    for mode <- [0, 1],
        split <- [false, true],
        side <- [0, 1],
        mask <- [0, 8, 16, 24, 30],
        ctrl <- [0, 56],
        scroll <- [0x73BF, 0x7FBF, 0x73FF] do
      s = %{
        base
        | vram: vram,
          exram: exram,
          oam: oam,
          nt_source: {0, 1, 2, 3},
          fill_tile: 3,
          fill_attr: 2,
          scanline: 24,
          v: scroll,
          t: 0x041F,
          x: 7,
          mask: mask,
          ctrl: ctrl,
          exram_mode: mode,
          ext_chr_hi: 0,
          split_en: split,
          split_side: side,
          split_tile: 4,
          split_chr: 2,
          split_scroll: 239
      }

      expected = NxNes.ReferencePPU.render_scanline(s)
      {pixels, status, v} = fun.(PPU.pack(s) |> Batch.resident(), rom) |> Batch.host()
      assert Nx.to_binary(pixels) == hd(expected.fb)
      assert Nx.to_number(status) == expected.status
      assert Nx.to_number(v) == expected.v
    end
  end

  test "APU boundary steps match base and MMC5 sequencers, envelopes, sweep and PCM" do
    fun = EXLA.jit(&APU.advance/2, client: :host)

    for mode <- [4, 5], cycle <- [7456, 14912, 22370, 29828, 29829, 37280, 37281] do
      s = fixture()
      s = %{s | frame_mode: mode, seq_cycle: cycle, m5seq: 7456, sample_acc: 0.99}
      expected = NxNes.ReferenceAPU.advance(s, 1)

      {actual, pcm, count} =
        fun.(APU.pack(s) |> Batch.resident(), Nx.tensor(1, type: :s32)) |> Batch.host()

      assert_state(actual, APU.pack(expected))
      assert Nx.to_number(pcm) == hd(expected.samples)
      assert Nx.to_number(count) == 1
    end
  end

  test "APU state stays resident across continuous intervals and outputs identical PCM" do
    fun = EXLA.jit(&APU.run/2, client: :host)
    s = fixture()

    Enum.reduce([100, 7457, 29830, 29830], {s, APU.pack(s) |> Batch.resident()}, fn cycles,
                                                                                    {ref, nx} ->
      expected = NxNes.ReferenceAPU.run(%{ref | samples: []}, cycles)
      {nx, pcm, count, left} = fun.(nx, Nx.tensor(cycles, type: :s32))
      assert Nx.to_number(left) == 0
      assert %EXLA.Backend{} = nx.f_lp.data
      actual_pcm = Nx.to_flat_list(pcm) |> Enum.take(Nx.to_number(count))
      assert actual_pcm == Enum.reverse(expected.samples)
      assert_state(Batch.host(nx), APU.pack(expected))
      {expected, nx}
    end)
  end

  test "unsupported audio devices are rejected" do
    assert_raise ArgumentError, fn ->
      apply(APU, :pack, [%{fixture() | dmc: %Beamicom.NES.APU.DMC{}}])
    end
  end

  test "LFSR jump preserves both noise modes over zero, short and multi-jump spans" do
    fun = EXLA.jit(&APU.advance/2, client: :host)

    for mode <- [false, true], shift <- [1, 31, 1023, 32767], dc <- [0, 1, 3, 7, 21, 41, 200] do
      s = fixture()
      s = %{s | noise: %{s.noise | mode: mode, period: 0}, noise_shift: shift}
      expected = NxNes.ReferenceAPU.advance(s, dc)

      {actual, _, _} =
        fun.(APU.pack(s) |> Batch.resident(), Nx.tensor(dc, type: :s32)) |> Batch.host()

      assert_state(actual, APU.pack(expected))
    end
  end

  test "packed integer/float buffers preserve continuous audio and state" do
    s = fixture()
    initial = APU.pack(s) |> NxNes.PackedAPU.pack() |> Batch.resident()
    fun = EXLA.jit(&NxNes.PackedAPU.run/2, client: :host)

    Enum.reduce([100, 7457, 29830], {s, initial}, fn cycles, {ref, nx} ->
      expected = NxNes.ReferenceAPU.run(%{ref | samples: []}, cycles)
      {nx, pcm, count, left} = fun.(nx, Nx.tensor(cycles, type: :s32))
      assert Nx.to_number(left) == 0

      assert Nx.to_flat_list(pcm) |> Enum.take(Nx.to_number(count)) ==
               Enum.reverse(expected.samples)

      assert_state(nx |> NxNes.PackedAPU.unpack() |> Batch.host(), APU.pack(expected))
      {expected, nx}
    end)
  end

  test "a full audio buffer returns unconsumed cycles instead of truncating samples" do
    s = fixture()

    {actual, pcm, count, left} =
      EXLA.jit(&APU.run/2, client: :host).(
        APU.pack(s) |> Batch.resident(),
        Nx.tensor(100_000, type: :s32)
      )

    assert Nx.to_number(count) == 1024
    assert Nx.to_number(left) > 0
    expected = NxNes.ReferenceAPU.run(s, 100_000 - Nx.to_number(left))
    assert Nx.to_flat_list(pcm) == Enum.reverse(expected.samples)
    assert_state(Batch.host(actual), APU.pack(expected))
  end

  defp assert_state(a, e) do
    Enum.each(e, fn {k, v} ->
      if match?(%Nx.Tensor{}, v) do
        x = Nx.to_number(Map.fetch!(a, k))
        y = Nx.to_number(v)

        if is_float(y),
          do: assert_in_delta(x, y, 1.0e-12),
          else: assert(x == y, "#{k}: #{x} != #{y}")
      else
        assert_state(Map.fetch!(a, k), v)
      end
    end)
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
          | length: 10,
            linear: 8,
            linear_reload: 5,
            period: 27,
            reload_flag: true
        },
        noise: %{s.noise | length: 5, period: 4, vol: 6, env_start: true},
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
