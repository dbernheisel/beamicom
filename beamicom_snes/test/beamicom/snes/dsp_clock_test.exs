defmodule Beamicom.SNES.DSPClockTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.DSP
  alias Beamicom.SNES.DSP.{Arithmetic, Echo, Envelope, Mixer, Voice, VoicePipeline}

  test "one rendered sample is the same 32 clock transitions" do
    {dsp, ram} = voice_fixture()

    {rendered, rendered_pcm} = DSP.render(dsp, ram, 1)
    {clocked, clocked_pcm} = DSP.clock(dsp, ram, 32)

    assert DSP.phase(clocked) == 0
    assert DSP.sample_counter(clocked) == 1
    assert clocked == rendered
    assert clocked_pcm == rendered_pcm
  end

  test "clock chunks preserve state and emitted PCM across sample boundaries" do
    {dsp, ram} = voice_fixture()
    clocks = 32 * 64

    {whole, whole_pcm} = DSP.clock(dsp, ram, clocks)

    {chunked, chunked_pcm} =
      clock_chunks(dsp, ram, [1, 31, 32, 33, clocks - 97], :native)

    assert chunked == whole
    assert chunked_pcm == whole_pcm
    assert DSP.phase(chunked) == 0
    assert DSP.sample_counter(chunked) == 64
  end

  test "a sample latches registers at phase zero" do
    {dsp, ram} = voice_fixture()
    {dsp, _startup} = DSP.render(dsp, ram, 8)
    {dsp, <<>>} = DSP.clock(dsp, ram)

    assert DSP.phase(dsp) == 1
    assert DSP.latched_register(dsp, 0x0C) == 0x7F

    dsp = DSP.write(dsp, 0x0C, 0)
    {dsp, first_pcm} = DSP.clock(dsp, ram, 31)
    {_dsp, second_pcm} = DSP.clock(dsp, ram, 32)

    assert first_pcm != <<0, 0, 0, 0>>
    assert <<0::signed-little-16, right::signed-little-16>> = second_pcm
    assert right != 0
  end

  test "signed arithmetic shifts negative odd values toward negative infinity" do
    assert Arithmetic.shift_right(-3, 1) == -2
    assert Arithmetic.shift_right(-5, 1) == -3
    assert Arithmetic.shift_right(5, 1) == 2
    assert Mixer.finalize({-1, -129}, {127, 127}, false) == {-1, -128}
  end

  test "main and echo buses saturate at each accumulation stage" do
    assert Mixer.accumulate({32_760, -32_760}, {100, -100}) == {32_767, -32_768}
    assert Mixer.accumulate({32_767, -32_768}, {-100, 100}) == {32_667, -32_668}

    assert Echo.accumulate({32_760, -32_760}, {100, -100}) == {32_767, -32_768}
    assert Echo.accumulate({32_767, -32_768}, {-100, 100}) == {32_667, -32_668}
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "Nx main-bus mixing clamps after each voice in order" do
      controls =
        List.duplicate({0, 0x7F, 0x7F, 0, 0, 0}, 8)
        |> List.to_tuple()

      mixer = {controls, false, 0x7F, 0x7F, 0}
      row = [32_760, 32_760, -32_760, 0, 0, 0, 0, 0]

      expected_bus =
        Enum.reduce(row, {0, 0}, fn sample, bus ->
          contribution = div(sample * 0x7F, 128)
          Mixer.accumulate(bus, {contribution, contribution})
        end)

      expected = Mixer.finalize(expected_bus, {0x7F, 0x7F}, false)

      assert <<left::signed-little-16, right::signed-little-16>> =
               Beamicom.SNES.Nx.DSPRenderer.render([row], mixer)

      assert {left, right} == expected
    end

    test "Nx-selected block and clock APIs preserve native state and PCM" do
      {dsp, ram} = voice_fixture()
      clocks = 32 * Beamicom.SNES.Nx.DSPRenderer.synthesis_minimum_frames()

      {native_block, native_block_pcm} =
        DSP.render(dsp, ram, Beamicom.SNES.Nx.DSPRenderer.synthesis_minimum_frames())

      {nx_block, nx_block_pcm} =
        DSP.render(
          dsp,
          ram,
          Beamicom.SNES.Nx.DSPRenderer.synthesis_minimum_frames(),
          Beamicom.SNES.Nx.DSPRenderer
        )

      assert nx_block == native_block
      assert nx_block_pcm == native_block_pcm

      {native_clock, native_clock_pcm} = DSP.clock(dsp, ram, clocks)

      {nx_clock, nx_clock_pcm} =
        DSP.clock(dsp, ram, clocks, Beamicom.SNES.Nx.DSPRenderer)

      assert nx_clock == native_clock
      assert nx_clock_pcm == native_clock_pcm

      chunks = [1, 31, 32, 33, clocks - 97]
      {native_chunks, native_chunks_pcm} = clock_chunks(dsp, ram, chunks, :native)

      {nx_chunks, nx_chunks_pcm} =
        clock_chunks(dsp, ram, chunks, Beamicom.SNES.Nx.DSPRenderer)

      assert nx_chunks == native_chunks
      assert nx_chunks_pcm == native_chunks_pcm
    end

    test "Nx-selected rendering matches scalar ordered saturation" do
      {dsp, ram} = saturating_voice_fixture()
      frames = Beamicom.SNES.Nx.DSPRenderer.synthesis_minimum_frames()

      {native, native_pcm} = DSP.render(dsp, ram, frames)
      {nx, nx_pcm} = DSP.render(dsp, ram, frames, Beamicom.SNES.Nx.DSPRenderer)

      assert nx == native
      assert nx_pcm == native_pcm

      assert <<left::signed-little-16, right::signed-little-16, _::binary>> = native_pcm
      assert abs(left) < 1_000
      assert abs(right) < 1_000
    end
  end

  defp clock_chunks(dsp, ram, chunks, renderer) do
    Enum.reduce(chunks, {dsp, <<>>}, fn clocks, {dsp, pcm} ->
      {dsp, chunk} = DSP.clock(dsp, ram, clocks, renderer)
      {dsp, pcm <> chunk}
    end)
  end

  defp voice_fixture do
    ram =
      [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, 0xC3}]
      |> Kernel.++(
        Enum.with_index(List.duplicate(0x77, 8), 0x201)
        |> Enum.map(fn {value, address} -> {address, value} end)
      )
      |> Enum.reduce(:array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
        :array.set(address, value, ram)
      end)

    dsp =
      DSP.new()
      |> DSP.write(0x00, 0x7F)
      |> DSP.write(0x01, 0x7F)
      |> DSP.write(0x02, 0x00)
      |> DSP.write(0x03, 0x10)
      |> DSP.write(0x04, 0x00)
      |> DSP.write(0x07, 0x7F)
      |> DSP.write(0x0C, 0x7F)
      |> DSP.write(0x1C, 0x7F)
      |> DSP.write(0x5D, 0x01)
      |> DSP.write(0x4C, 0x01)

    {dsp, ram}
  end

  defp saturating_voice_fixture do
    dsp = DSP.new()

    positive = %{
      Voice.new(0)
      | active?: true,
        buffer: List.duplicate(32_766, 12) |> List.to_tuple(),
        envelope: 0x7FF,
        envelope_mode: Envelope.sustain(),
        hidden_envelope: 0x7FF
    }

    negative = %{
      positive
      | index: 2,
        buffer: List.duplicate(-32_768, 12) |> List.to_tuple()
    }

    voice_pipeline =
      dsp.clock.voice_pipeline
      |> VoicePipeline.replace_voice(0, positive)
      |> VoicePipeline.replace_voice(1, %{positive | index: 1})
      |> VoicePipeline.replace_voice(2, negative)

    dsp = put_in(dsp.clock.voice_pipeline, voice_pipeline)

    dsp =
      Enum.reduce(0..2, dsp, fn index, dsp ->
        dsp
        |> DSP.write(index * 0x10, 0x7F)
        |> DSP.write(index * 0x10 + 1, 0x7F)
        |> DSP.write(index * 0x10 + 7, 0x7F)
      end)
      |> DSP.write(0x0C, 0x7F)
      |> DSP.write(0x1C, 0x7F)

    {dsp, :array.new(0x10000, default: 0, fixed: true)}
  end
end
