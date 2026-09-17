Code.require_file("../../../test_helpers/dsp_trace.ex", __DIR__)
Code.require_file("../../../test_helpers/dsp_reference_vectors.ex", __DIR__)

defmodule Beamicom.SNES.DSPReferenceHarnessTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.DSPReferenceVectors
  alias Beamicom.SNES.DSPTrace

  @native_renderer_version "phase-scalar-v2"
  @nx_renderer_version "phase-scalar-v2"
  @renderer_goldens %{
    native: %{
      pcm: "9dae002e7e08e5b4c02241466627b6a6113d739d20f9ea8633dea745ab4b8ec7",
      state: "39fe3ade43d98828cdc7fea370325b47d154188de08c30d196e4313efe0c3195"
    },
    nx: %{
      pcm: "f224439d3dae9e1d38384362e94c487bade58220079ce507ee0704e811933d5f",
      state: "011be7872e599a5dd7951e7eed5801a33c7c71d7a7ab7ba031057e4f4846617c"
    }
  }

  test "one clock at a time and a multi-sample block reach identical output and state" do
    vector = DSPReferenceVectors.vector(:interpolation)
    clock_count = 21 * 32

    single_clock =
      vector
      |> Map.put(:actions, List.duplicate(:clock, clock_count))
      |> DSPTrace.run(renderer_version: @native_renderer_version)

    sample_block = DSPTrace.run(vector, renderer_version: @native_renderer_version)

    assert :ok = DSPTrace.compare(single_clock, sample_block, vector.inspect)
  end

  test "clock and block paths preserve identical NON noise state" do
    vector = DSPReferenceVectors.vector(:noise)
    clock_count = 16 * 32

    single_clock =
      vector
      |> Map.put(:actions, [
        {:write_register, 0x3D, 0x01},
        {:write_register, 0x6C, 0x1F} | List.duplicate(:clock, clock_count)
      ])
      |> DSPTrace.run(renderer_version: @native_renderer_version)

    sample_block = DSPTrace.run(vector, renderer_version: @native_renderer_version)

    assert single_clock.dsp.clock.noise == sample_block.dsp.clock.noise
    assert single_clock.dsp.clock.pipeline == sample_block.dsp.clock.pipeline
    assert single_clock.dsp.clock.voice_pipeline == sample_block.dsp.clock.voice_pipeline
    assert single_clock.dsp.clock.echo_state == sample_block.dsp.clock.echo_state
    assert single_clock.dsp.clock.registers == sample_block.dsp.clock.registers
    assert Map.from_struct(single_clock.dsp.clock) == Map.from_struct(sample_block.dsp.clock)
    assert :ok = DSPTrace.compare(single_clock, sample_block, vector.inspect)
  end

  test "partial clocks preserve phase and render only at a sample boundary" do
    trace = DSPTrace.new(renderer_version: @native_renderer_version)
    trace = DSPTrace.advance_clocks(trace, 31)

    assert trace.clock == 31
    assert trace.sample_phase == 31
    assert trace.sample_count == 0
    assert DSPTrace.pcm(trace) == <<>>

    trace = DSPTrace.clock(trace)

    assert trace.clock == 32
    assert trace.sample_phase == 0
    assert trace.sample_count == 1
    assert DSPTrace.pcm(trace) == <<0, 0, 0, 0>>
  end

  test "trace exposes PCM, register, voice, and RAM inspection" do
    vector = DSPReferenceVectors.vector(:interpolation)
    trace = DSPTrace.run(vector, renderer_version: @native_renderer_version)

    assert byte_size(DSPTrace.pcm(trace)) == 21 * 4
    assert DSPTrace.read_register(trace, 0x03) == 0x04
    assert DSPTrace.read_voice(trace, 0).active?
    assert DSPTrace.read_ram(trace, 0x201) == 0x07

    assert %{registers: [{0x03, 0x04}], voices: [{0, %{active?: true}}], ram: [{0x201, 0x07}]} =
             DSPTrace.snapshot(trace, registers: [0x03], voices: [0], ram: [0x201])
  end

  test "golden identity includes vector and renderer versions" do
    vector = DSPReferenceVectors.vector(:interpolation)
    trace = DSPTrace.run(vector, renderer_version: @native_renderer_version)
    hashes = DSPTrace.golden_hashes(trace, vector.inspect)

    refute hashes ==
             DSPTrace.golden_hashes(%{trace | vector_version: 4}, vector.inspect)

    refute hashes ==
             DSPTrace.golden_hashes(%{trace | renderer_id: "native-copy"}, vector.inspect)

    refute hashes ==
             DSPTrace.golden_hashes(%{trace | renderer_version: "scalar-v2"}, vector.inspect)
  end

  test "first-divergence reports identify PCM sample, register, and RAM positions" do
    vector = DSPReferenceVectors.vector(:interpolation)
    reference = DSPTrace.run(vector, renderer_version: @native_renderer_version)

    <<first::binary-size(4), sample::signed-little-16, rest::binary>> = DSPTrace.pcm(reference)

    corrupted_pcm = %{
      DSPTrace.snapshot(reference, vector.inspect)
      | pcm: first <> <<sample + 1::signed-little-16>> <> rest
    }

    assert {:error, pcm_message} = DSPTrace.compare(reference, corrupted_pcm, vector.inspect)
    assert pcm_message =~ "PCM divergence at clock 64, sample 1, channel left"
    assert pcm_message =~ "expected"
    assert pcm_message =~ "actual"

    corrupted_register = DSPTrace.write_register(reference, 0x02, 0xAA)

    assert {:error, register_message} =
             DSPTrace.compare(reference, corrupted_register, vector.inspect)

    assert register_message =~ "register divergence"
    assert register_message =~ "address 0x0002"

    corrupted_ram = DSPTrace.write_ram(reference, 0x204, 0xAA)
    assert {:error, ram_message} = DSPTrace.compare(reference, corrupted_ram, vector.inspect)
    assert ram_message =~ "RAM divergence"
    assert ram_message =~ "address 0x0204"
  end

  for vector <- DSPReferenceVectors.active() do
    @vector vector
    @tag :golden

    test "#{vector.id} native golden includes vector and renderer versions" do
      vector = @vector
      trace = DSPTrace.run(vector, renderer_version: @native_renderer_version)
      hashes = DSPTrace.golden_hashes(trace, vector.inspect)

      assert hashes == vector.golden
    end
  end

  for vector <- DSPReferenceVectors.pending() do
    @tag skip: vector.skip

    test "#{vector.id} reference vector" do
      flunk("remove the skip and add trusted reference expectations when this feature lands")
    end
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    @tag timeout: Kernel.to_timeout(minute: 2)
    test "renderer selection preserves authoritative phase-pipeline PCM and state" do
      vector =
        DSPReferenceVectors.vector(:interpolation)
        |> Map.put(:actions, [{:render_samples, 4_096}])

      native = DSPTrace.run(vector, renderer_version: @native_renderer_version)

      nx =
        DSPTrace.run(vector,
          renderer: Beamicom.SNES.Nx.DSPRenderer,
          renderer_version: @nx_renderer_version
        )

      assert :ok = DSPTrace.compare(native, nx, vector.inspect)

      native_hashes = DSPTrace.golden_hashes(native, vector.inspect)
      nx_hashes = DSPTrace.golden_hashes(nx, vector.inspect)

      assert %{native: native_hashes, nx: nx_hashes} == @renderer_goldens
      refute native_hashes == nx_hashes
      assert DSPTrace.pcm(native) == DSPTrace.pcm(nx)
      assert native.dsp == nx.dsp
    end
  else
    @tag skip: "skipped: Beamicom.SNES.Nx.DSPRenderer is unavailable"
    test "renderer selection preserves authoritative phase-pipeline PCM and state" do
      flunk("Nx renderer availability changed after this test was compiled")
    end
  end
end
