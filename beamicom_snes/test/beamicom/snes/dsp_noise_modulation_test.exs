defmodule Beamicom.SNES.DSPNoiseModulationTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.DSP
  alias Beamicom.SNES.DSP.{Arithmetic, Modulation, Noise, Pipeline}

  @first_noise_ticks [
    :never,
    2048,
    1040,
    536,
    1024,
    272,
    536,
    512,
    272,
    216,
    256,
    80,
    56,
    128,
    80,
    56,
    64,
    32,
    16,
    32,
    8,
    16,
    16,
    8,
    6,
    8,
    2,
    1,
    4,
    2,
    2,
    1
  ]

  test "noise reset state and rate-31 sequence match the 15-bit S-DSP LFSR" do
    noise = Noise.new()

    assert noise.lfsr == 0x4000
    assert noise.counter == 0
    assert Noise.sample(noise) == -32_768
    assert Noise.sample_from_lfsr(0x7FFF) == -2
    assert Noise.next_lfsr(0x4000) == 0x2000

    expected = [
      0x2000,
      0x1000,
      0x0800,
      0x0400,
      0x0200,
      0x0100,
      0x0080,
      0x0040,
      0x0020,
      0x0010,
      0x0008,
      0x0004,
      0x0002,
      0x4001,
      0x6000,
      0x3000
    ]

    {actual, noise} =
      Enum.map_reduce(expected, noise, fn _expected, noise ->
        noise = Noise.clock(noise, 0x1F, 30_719)
        {noise.lfsr, noise}
      end)

    assert actual == expected
    assert Noise.reset(noise) == Noise.new()
  end

  test "FLG soft reset preserves the running noise LFSR" do
    noise = %{Noise.new() | lfsr: 0x1234, counter: 17, sample: 0x2468}
    dsp = put_in(DSP.new().clock.noise, noise)

    assert DSP.write(dsp, 0x6C, 0x80).clock.noise == noise
  end

  test "all 32 FLG rates have the reference first-tick timing" do
    actual =
      0..31
      |> Enum.map(fn rate -> first_noise_tick(rate) end)

    assert actual == @first_noise_ticks

    assert Noise.clock(Noise.new(), 0xFF, 30_719) ==
             Noise.clock(Noise.new(), 0x1F, 30_719)
  end

  test "rate zero never advances the LFSR during a complete counter period" do
    noise =
      Enum.reduce(1..30_720, Noise.new(), fn elapsed, noise ->
        Noise.clock(noise, 0, Integer.mod(-elapsed, 30_720))
      end)

    assert noise.lfsr == 0x4000
    assert Noise.sample(noise) == -32_768
  end

  test "NON selects the current noise sample independently for every voice" do
    noise_sample = Noise.sample(Noise.new())

    assert Noise.select_source(12_345, noise_sample, 0b0000_0101, 0) == noise_sample
    assert Noise.select_source(12_345, noise_sample, 0b0000_0101, 1) == 12_345
    assert Noise.select_source(12_345, noise_sample, 0b0000_0101, 2) == noise_sample
    assert Noise.select_source(12_345, noise_sample, 0, 2) == 12_345
  end

  test "PMON uses signed previous-voice output and hardware pitch limits" do
    assert Modulation.modulated_pitch(1024, -33) == 1022
    assert Modulation.modulated_pitch(0x3FFF, -32_768) == 0
    assert Modulation.modulated_pitch(0x3FFF, 32_767) == 0x7FEE

    pipeline = Pipeline.new() |> Pipeline.record_voice(0, -33)

    assert Modulation.pitch(1024, 1, 0b0000_0010, pipeline) == 1022
    assert Modulation.pitch(1024, 1, 0, pipeline) == 1024
    assert Modulation.pitch(1024, 0, 0xFF, pipeline) == 1024
    assert Modulation.pitch(1024, 1, pipeline) == 1024
  end

  test "PMON chains post-envelope outputs, including a noise source and reset silence" do
    voice0_output =
      12_345
      |> Noise.select_source(Noise.sample(Noise.new()), 0b0000_0001, 0)
      |> apply_envelope(0x0400)

    pipeline = Pipeline.new() |> Pipeline.record_voice(0, voice0_output)

    assert voice0_output == -16_384
    assert Modulation.pitch(4096, 1, 0b0000_0110, pipeline) == 2048

    voice1_output = apply_envelope(8192, 0x07FF)
    pipeline = Pipeline.record_voice(pipeline, 1, voice1_output)

    assert Modulation.pitch(4096, 2, 0b0000_0110, pipeline) == 5116

    reset_pipeline = Pipeline.new() |> Pipeline.record_voice(0, 0)
    assert Modulation.pitch(4096, 1, 0b0000_0010, reset_pipeline) == 4096
  end

  defp first_noise_tick(0), do: :never

  defp first_noise_tick(rate) do
    initial = Noise.new()

    Enum.find(1..30_720, fn elapsed ->
      counter = Integer.mod(-elapsed, 30_720)
      Noise.clock(initial, rate, counter).lfsr != initial.lfsr
    end)
  end

  defp apply_envelope(sample, envelope) do
    sample
    |> Kernel.*(envelope)
    |> Arithmetic.shift_right(11)
    |> band(-2)
  end
end
