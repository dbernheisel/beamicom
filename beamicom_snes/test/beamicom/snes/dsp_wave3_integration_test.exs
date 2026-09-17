Code.require_file("../../../test_helpers/dsp_renderer_spy.ex", __DIR__)

defmodule Beamicom.SNES.DSPWave3IntegrationTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{APU, DSP, SPC700}
  alias Beamicom.SNES.DSP.{Envelope, Voice, VoicePipeline}

  test "NON and PMON force the scalar oracle while ordinary mixing remains Nx-eligible" do
    dsp = DSP.new()
    refute DSP.scalar_required?(dsp)

    assert dsp |> DSP.write(0x3D, 0x01) |> DSP.scalar_required?()
    assert dsp |> DSP.write(0x2D, 0x02) |> DSP.scalar_required?()
    assert dsp |> DSP.write(0x2C, 0x01) |> DSP.scalar_required?()
  end

  test "configured echo fences only its ring regions on the APU RAM timeline" do
    dsp = DSP.new() |> DSP.write(0x6D, 0x20)

    assert {:regions, addresses, [{0, 4}, {0x2000, 4}]} =
             DSP.ram_dependency_addresses(dsp, ram([]), 32)

    assert addresses == MapSet.new(0..3)
  end

  test "BRR dependency fencing covers PMON's maximum forward traversal" do
    dsp = DSP.new() |> DSP.write(0x2D, 0x02)

    voice = %{
      VoicePipeline.voice(dsp.clock.voice_pipeline, 1)
      | active?: true,
        pitch: 1,
        source: 0,
        brr_address: 0x2000
    }

    dsp =
      put_in(
        dsp.clock.voice_pipeline,
        VoicePipeline.replace_voice(dsp.clock.voice_pipeline, 1, voice)
      )

    dependencies = DSP.ram_dependency_addresses(dsp, ram([]), 32)

    assert dependency_member?(dependencies, 0x2000 + 4 * 9)
  end

  test "BRR dependency fencing retains live and already-latched directory state" do
    ram =
      []
      |> ram()
      |> put_word(0x1004, 0x3000)
      |> put_word(0x1006, 0x3100)
      |> put_word(0x2004, 0x4000)
      |> put_word(0x2006, 0x4100)

    dsp = DSP.new() |> DSP.write(0x5D, 0x20)
    voice = %{Voice.new(0) | active?: true, source: 1, brr_address: 0x5000}

    voice_pipeline =
      dsp.clock.voice_pipeline
      |> VoicePipeline.replace_voice(0, voice)
      |> Map.update!(:brr, fn brr ->
        %{brr | latched_bank: 0x10, directory_address: 0x1208, next_address: 0x6000}
      end)

    dsp = put_in(dsp.clock.voice_pipeline, voice_pipeline)
    dependencies = DSP.ram_dependency_addresses(dsp, ram, 32)

    for address <- [0x1004, 0x1208, 0x2004, 0x3000, 0x4000, 0x5000, 0x6000] do
      assert dependency_member?(dependencies, address),
             "missing dependency #{Integer.to_string(address, 16)}"
    end
  end

  defp dependency_member?(dependencies, address) when is_struct(dependencies, MapSet),
    do: MapSet.member?(dependencies, address)

  defp dependency_member?({:regions, addresses, regions}, address) do
    MapSet.member?(addresses, address) or region_member?(regions, address)
  end

  defp dependency_member?({:dependencies, addresses, write_regions, read_regions}, address) do
    MapSet.member?(addresses, address) or region_member?(write_regions, address) or
      region_member?(read_regions, address)
  end

  defp region_member?(regions, address) do
    Enum.any?(regions, fn {base, length} -> (address - base &&& 0xFFFF) < length end)
  end

  test "NON selects the clocked noise source in live scalar rendering" do
    {dsp, ram} = legacy_voice_fixture([0, 0])
    {_decoded, decoded_pcm} = DSP.render(dsp, ram, 2)

    noisy = dsp |> DSP.write(0x3D, 0x01) |> DSP.write(0x6C, 0x1F)
    {noisy, noisy_pcm} = DSP.render(noisy, ram, 2)

    assert decoded_pcm == <<0::size(2)-unit(32)>>
    refute noisy_pcm == decoded_pcm
    refute noisy.clock.noise == dsp.clock.noise
  end

  test "PMON changes voice one pitch from voice zero's signed post-envelope output" do
    {dsp, ram} = legacy_voice_fixture([16_384, 4_096])
    dsp = dsp |> DSP.write(0x12, 0x00) |> DSP.write(0x13, 0x10)

    {plain, _pcm} = DSP.render(dsp, ram, 2)
    {modulated, _pcm} = dsp |> DSP.write(0x2D, 0x02) |> DSP.render(ram, 2)

    refute DSP.voice(modulated, 1).gaussian_offset == DSP.voice(plain, 1).gaussian_offset
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "Nx-selected NON and PMON preserve the authoritative scalar pipeline" do
      {dsp, ram} = legacy_voice_fixture([16_384, 4_096])

      dsp =
        dsp
        |> DSP.write(0x3D, 0x01)
        |> DSP.write(0x2D, 0x02)
        |> DSP.write(0x6C, 0x1F)

      {native, native_pcm} = DSP.render(dsp, ram, 64)
      {nx, nx_pcm} = DSP.render(dsp, ram, 64, Beamicom.SNES.DSPRendererSpy)

      assert nx == native
      assert nx_pcm == native_pcm
      refute_receive {:dsp_renderer_spy, :mix, _frames}
      refute_receive {:dsp_renderer_spy, :synthesis, _frames}
    end

    test "Nx echo falls back when voice BRR reads can overlap echo RAM writes" do
      {dsp, ram} = legacy_voice_fixture([16_384])

      dsp =
        dsp
        |> DSP.write(0x2C, 0x7F)
        |> DSP.write(0x3C, 0x7F)
        |> DSP.write(0x6D, 0x00)
        |> DSP.write(0x7D, 0x01)
        |> DSP.write(0x7F, 0x7F)

      {native, native_ram, native_pcm} = DSP.clock_ram(dsp, ram, 64 * 32, :native)

      {nx, nx_ram, nx_pcm} =
        DSP.clock_ram(dsp, ram, 64 * 32, Beamicom.SNES.DSPRendererSpy)

      assert nx == native
      assert nx_ram == native_ram
      assert nx_pcm == native_pcm
      refute_receive {:dsp_renderer_spy, :echo, _frames}
    end

    test "pure echo tails preserve the authoritative scalar pipeline" do
      ram = ram([])

      dsp =
        DSP.new()
        |> DSP.write(0x2C, 0x7F)
        |> DSP.write(0x3C, 0x7F)
        |> DSP.write(0x6D, 0x20)
        |> DSP.write(0x7D, 0x01)
        |> DSP.write(0x7F, 0x7F)

      {native, native_ram, native_pcm} = DSP.clock_ram(dsp, ram, 64 * 32, :native)

      {nx, nx_ram, nx_pcm} =
        DSP.clock_ram(dsp, ram, 64 * 32, Beamicom.SNES.DSPRendererSpy)

      assert nx == native
      assert nx_ram == native_ram
      assert nx_pcm == native_pcm
      refute_receive {:dsp_renderer_spy, :echo, _frames}
    end
  end

  test "clock_ram interleaves echo reads and writes and is partition equivalent" do
    ram =
      []
      |> ram()
      |> put_word(0x2004, 0x2000)
      |> put_word(0x2006, -0x2000)

    dsp =
      DSP.new()
      |> DSP.write(0x2C, 0x7F)
      |> DSP.write(0x3C, 0x7F)
      |> DSP.write(0x0D, 0x7F)
      |> DSP.write(0x6D, 0x20)
      |> DSP.write(0x7D, 0x01)
      |> DSP.write(0x7F, 0x7F)

    whole = DSP.clock_ram(dsp, ram, 64)

    chunked =
      Enum.reduce([22, 1, 6, 1, 1, 1, 22, 1, 6, 1, 1, 1], {dsp, ram, <<>>}, fn clocks,
                                                                               {dsp, ram, pcm} ->
        {dsp, ram, chunk} = DSP.clock_ram(dsp, ram, clocks)
        {dsp, ram, pcm <> chunk}
      end)

    assert chunked == whole

    {dsp, ram, <<_silence::binary-size(4), left::signed-little-16, right::signed-little-16>>} =
      whole

    assert left > 0
    assert right < 0
    assert :array.get(0x2004, ram) != 0x00
    assert dsp.clock.echo_state.page == 0x20
  end

  test "legacy clock and render APIs retain their return shape with configured echo" do
    ram = ram([])
    dsp = DSP.new() |> DSP.write(0x2C, 1)

    assert {%DSP{}, pcm} = DSP.clock(dsp, ram, 32)
    assert byte_size(pcm) == 4
    assert {%DSP{}, render_pcm} = DSP.render(dsp, ram, 1)
    assert byte_size(render_pcm) == 4
  end

  test "APU timeline retains phase-timed echo writes in shared SPC RAM" do
    ram =
      []
      |> ram()
      |> put_word(0x2004, 0x2000)
      |> put_word(0x2006, -0x2000)

    dsp =
      DSP.new()
      |> DSP.write(0x0D, 0x7F)
      |> DSP.write(0x6D, 0x20)
      |> DSP.write(0x7D, 0x01)
      |> DSP.write(0x7F, 0x7F)

    spc = %{SPC700.new(ram, 0) | dsp: dsp, stopped?: true}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}
    apu = APU.advance(apu, 1_344, :ntsc)

    assert :array.get(0x2004, apu.spc.ram) != 0x00
    assert apu.ram == apu.spc.ram
    assert apu.spc.dsp.clock.echo_state.page == 0x20
  end

  test "APU reports the PCM frame only after the full echo sample commits" do
    ram = ram([])
    dsp = DSP.new() |> DSP.write(0x2C, 0x01)
    spc = %{SPC700.new(ram, 0) | dsp: dsp, stopped?: true}
    apu = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    apu = APU.advance(apu, 582, :pal)
    assert {0, <<>>, apu} = APU.take_pcm(apu)

    apu = APU.advance(apu, 84, :pal)
    assert {1, <<_frame::binary-size(4)>>, _apu} = APU.take_pcm(apu)
  end

  test "every partial echo phase reports one frame per four PCM bytes" do
    ram = ram([])
    dsp = DSP.new() |> DSP.write(0x2C, 0x01)
    spc = %{SPC700.new(ram, 0) | dsp: dsp, stopped?: true}
    initial = %{APU.new() | ram: ram, spc: spc, ipl_state: :running}

    for spc_cycles <- 0..31 do
      master_clocks = div(spc_cycles * 21_281_370 + 1_023_999, 1_024_000)
      apu = APU.advance(initial, master_clocks, :pal)
      {frames, pcm, _apu} = APU.take_pcm(apu)

      assert byte_size(pcm) == frames * 4,
             "mismatched audio chunk after #{spc_cycles} SPC clocks"
    end
  end

  defp legacy_voice_fixture(samples) do
    dsp = DSP.new()

    voice_pipeline =
      samples
      |> Enum.with_index()
      |> Enum.reduce(dsp.clock.voice_pipeline, fn {sample, index}, voice_pipeline ->
        voice = %{
          Voice.new(index)
          | active?: true,
            buffer: List.duplicate(sample, 12) |> List.to_tuple(),
            envelope: 0x7FF,
            envelope_mode: Envelope.sustain(),
            hidden_envelope: 0x7FF
        }

        VoicePipeline.replace_voice(voice_pipeline, index, voice)
      end)

    dsp = put_in(dsp.clock.voice_pipeline, voice_pipeline)

    dsp =
      Enum.reduce(0..(length(samples) - 1), dsp, fn index, dsp ->
        dsp
        |> DSP.write(index * 0x10, 0x7F)
        |> DSP.write(index * 0x10 + 1, 0x7F)
        |> DSP.write(index * 0x10 + 7, 0x7F)
      end)
      |> DSP.write(0x0C, 0x7F)
      |> DSP.write(0x1C, 0x7F)

    {dsp, ram([])}
  end

  defp ram(bytes) do
    Enum.reduce(bytes, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end

  defp put_word(ram, address, value) do
    value = Bitwise.band(value, 0xFFFF)

    ram
    |> then(&:array.set(address, Bitwise.band(value, 0xFF), &1))
    |> then(&:array.set(address + 1, Bitwise.bsr(value, 8), &1))
  end
end
