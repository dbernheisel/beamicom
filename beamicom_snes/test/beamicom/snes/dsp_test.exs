defmodule Beamicom.SNES.DSPTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.DSP
  alias Beamicom.SNES.DSP.Envelope

  test "stores raw registers compactly without retired compatibility mirrors" do
    dsp = DSP.new() |> DSP.write(0x4C, 0xA5)

    assert is_tuple(dsp.registers)
    assert tuple_size(dsp.registers) == 128
    assert DSP.read(dsp, 0x4C) == 0xA5

    for field <- [:voices, :key_on, :key_off, :end_flags, :counter] do
      refute Map.has_key?(dsp, field)
    end
  end

  test "Gaussian interpolation shapes a low-pitched BRR transient" do
    {dsp, ram} = voice_fixture(0xC3, [0x07, 0x70, 0, 0, 0, 0, 0, 0], 0x0400)
    {dsp, <<0::size(8)-unit(32)>>} = DSP.render(dsp, ram, 8)
    {_dsp, pcm} = DSP.render(dsp, ram, 12)

    assert left_samples(pcm) == [
             22_958,
             25_555,
             26_445,
             25_527,
             22_903,
             18_841,
             13_961,
             9_077,
             5_057,
             2_294,
             762,
             134
           ]
  end

  test "KON holds pitch for five samples and starts the ADSR attack on the fifth" do
    {dsp, ram} = voice_fixture(0xC3, List.duplicate(0x77, 8), 0x0400)
    dsp = dsp |> DSP.write(0x05, 0x8F) |> DSP.write(0x06, 0xE0)

    {dsp, startup} = DSP.render(dsp, ram, 7)
    voice = DSP.voice(dsp, 0)

    assert startup == <<0::size(7)-unit(32)>>
    assert voice.keyon_delay == 0
    assert voice.gaussian_offset == 0
    assert voice.envelope == 0x400
    assert voice.envelope_mode == Envelope.attack()

    {dsp, <<0::size(32)>>} = DSP.render(dsp, ram, 1)
    {dsp, audible} = DSP.render(dsp, ram, 1)
    voice = DSP.voice(dsp, 0)

    refute audible == <<0, 0, 0, 0>>
    assert voice.gaussian_offset == 0x0800
    assert voice.envelope == 0x7FF
    assert voice.envelope_mode == Envelope.sustain()
  end

  test "KOFF releases at eight envelope units per sample instead of cutting the voice" do
    {dsp, ram} = voice_fixture(0xC3, List.duplicate(0x77, 8), 0x0400)
    {dsp, _startup} = DSP.render(dsp, ram, 7)
    assert DSP.voice(dsp, 0).envelope == 0x7F0

    {dsp, tail} = dsp |> DSP.write(0x5C, 0x01) |> DSP.render(ram, 253)
    voice = DSP.voice(dsp, 0)

    refute tail == :binary.copy(<<0>>, byte_size(tail))
    assert voice.active?
    assert voice.envelope == 8
    assert voice.envelope_mode == Envelope.release()

    {dsp, _last_frame} = DSP.render(dsp, ram, 1)
    voice = DSP.voice(dsp, 0)
    refute voice.active?
    assert voice.envelope == 0
  end

  test "GAIN clocks on the global counter and bent increase uses the hidden envelope" do
    counter = Envelope.next_counter(0)

    assert {true, 0, mode, 0x20} =
             Envelope.advance(true, 0, Envelope.sustain(), 0, 0, 0, 0xDE, counter)

    counter = Envelope.next_counter(counter)

    assert {true, 0x20, ^mode, 0x20} =
             Envelope.advance(true, 0, mode, 0x20, 0, 0, 0xDE, counter)

    assert {true, 0x620, ^mode, 0x620} =
             Envelope.advance(true, 0x600, mode, 0x5FF, 0, 0, 0xFF, counter)

    assert {true, 0x628, ^mode, 0x628} =
             Envelope.advance(true, 0x620, mode, 0x620, 0, 0, 0xFF, counter)
  end

  test "BRR prediction clamps to 16 bits then wraps to signed 15-bit samples" do
    vectors = [
      {0xC7,
       [
         28_672,
         -9_984,
         19_312,
         -18_760,
         11_084,
         -26_474,
         3_852,
         32_282,
         -6_600,
         22_484,
         -15_786,
         13_872,
         -23_860,
         6_302,
         -30_956,
         -350
       ]},
      {0xCB,
       [
         28_672,
         -2,
         1_788,
         32_080,
         -2,
         -1_408,
         25_988,
         -2,
         4_304,
         -28_660,
         -29_998,
         -1_644,
         -11_876,
         7_572,
         -11_298,
         34
       ]},
      {0xCF,
       [
         28_672,
         -2,
         5_372,
         -27_212,
         -24_592,
         6_590,
         -5_044,
         14_252,
         -7_158,
         4_228,
         -23_454,
         -16_908,
         17_346,
         -2,
         14_574,
         -10_678
       ]}
    ]

    for {header, expected} <- vectors do
      {dsp, ram} = voice_fixture(header, List.duplicate(0x77, 8), 0x1000)
      {dsp, _pcm} = DSP.render(dsp, ram, 7)

      assert Tuple.to_list(DSP.voice(dsp, 0).buffer) == Enum.take(expected, 12)
    end
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "Nx-selected rendering preserves the native Gaussian waveform" do
      fixtures = [
        {0xC3, [0x07, 0x70, 0, 0, 0, 0, 0, 0], 0x0400},
        {0xC1, List.duplicate(0x77, 8), 0x1000},
        {0xCF, List.duplicate(0x77, 8), 0x1000}
      ]

      for {header, bytes, pitch} <- fixtures do
        {dsp, ram} = voice_fixture(header, bytes, pitch)
        {native, native_pcm} = DSP.render(dsp, ram, 4_096)

        {nx, nx_pcm} =
          DSP.render(dsp, ram, 4_096, Beamicom.SNES.Nx.DSPRenderer)

        assert nx == native
        assert nx_pcm == native_pcm
      end
    end

    test "Nx-selected rendering preserves ADSR and KOFF release timing across chunks" do
      {dsp, ram} = voice_fixture(0xC3, List.duplicate(0x77, 8), 0x0400)
      dsp = dsp |> DSP.write(0x05, 0x8F) |> DSP.write(0x06, 0xE0)

      {native, native_pcm} = DSP.render(dsp, ram, 4_096)
      {nx, nx_pcm} = DSP.render(dsp, ram, 4_096, Beamicom.SNES.Nx.DSPRenderer)

      assert nx == native
      assert nx_pcm == native_pcm

      native = DSP.write(native, 0x5C, 0x01)
      nx = DSP.write(nx, 0x5C, 0x01)
      {native, native_pcm} = DSP.render(native, ram, 4_096)
      {nx, nx_pcm} = DSP.render(nx, ram, 4_096, Beamicom.SNES.Nx.DSPRenderer)

      assert nx == native
      assert nx_pcm == native_pcm
      refute DSP.voice(nx, 0).active?
    end

    test "aligned echo batching preserves clock-exact state, PCM, and shared RAM" do
      {dsp, ram} = voice_fixture(0xC3, List.duplicate(0x77, 8), 0x0400)

      dsp =
        dsp
        |> DSP.write(0x2C, 0x20)
        |> DSP.write(0x3C, 0xE0)
        |> DSP.write(0x0D, 0x40)
        |> DSP.write(0x4D, 0x01)
        |> DSP.write(0x6D, 0x20)
        |> DSP.write(0x7D, 0x01)
        |> DSP.write(0x0F, 0x7F)

      clocks = 128 * 32
      {clocked, clocked_ram, clocked_pcm} = clock_one_at_a_time(dsp, ram, clocks)
      {batched, batched_ram, batched_pcm} = DSP.clock_ram(dsp, ram, clocks, :native)

      assert batched == clocked
      assert batched_pcm == clocked_pcm
      assert batched_ram == clocked_ram
    end
  end

  defp voice_fixture(header, bytes, pitch) do
    ram =
      [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, header}]
      |> Kernel.++(
        Enum.with_index(bytes, 0x201)
        |> Enum.map(fn {value, address} -> {address, value} end)
      )
      |> Enum.reduce(:array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
        :array.set(address, value, ram)
      end)

    dsp =
      DSP.new()
      |> DSP.write(0x00, 0x7F)
      |> DSP.write(0x01, 0x7F)
      |> DSP.write(0x02, pitch &&& 0xFF)
      |> DSP.write(0x03, pitch >>> 8)
      |> DSP.write(0x04, 0x00)
      |> DSP.write(0x07, 0x7F)
      |> DSP.write(0x0C, 0x7F)
      |> DSP.write(0x1C, 0x7F)
      |> DSP.write(0x5D, 0x01)
      |> DSP.write(0x4C, 0x01)

    {dsp, ram}
  end

  defp left_samples(pcm) do
    for <<left::signed-little-16, _right::signed-little-16 <- pcm>>, do: left
  end

  defp clock_one_at_a_time(dsp, ram, clocks) do
    Enum.reduce(1..clocks, {dsp, ram, []}, fn _, {dsp, ram, pcm} ->
      {dsp, ram, chunk} = DSP.clock_ram(dsp, ram, 1, :native)
      {dsp, ram, [chunk | pcm]}
    end)
    |> then(fn {dsp, ram, pcm} ->
      {dsp, ram, pcm |> Enum.reverse() |> IO.iodata_to_binary()}
    end)
  end
end
