defmodule Beamicom.GB.Nx.PPURendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.{APU, DiagnosticROM, PPU, SaveState, System}

  for {model, media} <- [dmg: DiagnosticROM.build(), cgb: DiagnosticROM.build_cgb()] do
    test "#{model} frame composition is pixel-exact" do
      media = unquote(Macro.escape(media))
      {:ok, native} = System.load(media, [])
      native = put_in(native.bus.ppu, PPU.set_renderer(native.bus.ppu, :native))
      native = put_in(native.bus.apu, APU.set_renderer(native.bus.apu, :native))
      {_native, [native_video, native_audio]} = System.run_slice(native)

      {:ok, accelerated} = System.load(media, [])
      {_accelerated, [video, audio]} = System.run_slice(accelerated)

      assert video.data == native_video.data
      assert audio.data == native_audio.data
      assert video.pixel_format == native_video.pixel_format
    end
  end

  test "Nx-backed machines survive save and restore at a frame boundary" do
    media = DiagnosticROM.build_cgb()
    {:ok, machine} = System.load(media, [])
    {machine, _outputs} = System.run_slice(machine)
    {state, rom} = SaveState.split(machine)
    assert {:ok, restored} = SaveState.merge(state, rom)

    {_machine, expected} = System.run_slice(machine)
    {_restored, actual} = System.run_slice(restored)
    assert actual == expected
  end

  test "block APU mixing is exact for routed audible channel output" do
    native = audible_audio(:native)
    accelerated = audible_audio(Beamicom.GB.Nx.APUBlockRenderer)

    assert accelerated == native
    refute native == :binary.copy(<<0>>, byte_size(native))
  end

  test "event-block APU synthesis is exact for routed audible channel output" do
    native = audible_audio(:native)
    accelerated = audible_audio(Beamicom.GB.Nx.APUSynthRenderer)

    assert accelerated == native
    refute native == :binary.copy(<<0>>, byte_size(native))
  end

  test "event-block synthesis stays exact across all channels and register epochs" do
    assert complex_audio(Beamicom.GB.Nx.APUSynthRenderer) == complex_audio(:native)
  end

  test "Nx wrapper compiles the core against both optional renderers" do
    assert Beamicom.GB.Nx.backends() == %{
             ppu: Beamicom.GB.Nx.PPURenderer,
             apu: Beamicom.GB.Nx.APUBlockRenderer
           }
  end

  defp audible_audio(renderer) do
    apu =
      APU.new(model: :cgb)
      |> APU.set_renderer(renderer)
      |> APU.write(0xFF26, 0x80)
      |> APU.write(0xFF16, 0x80)
      |> APU.write(0xFF17, 0xF3)
      |> APU.write(0xFF18, 0x40)
      |> APU.write(0xFF19, 0x87)
      |> APU.write(0xFF24, 0x77)
      |> APU.write(0xFF25, 0x22)
      |> APU.tick(70_224)

    {_count, pcm, _apu} = APU.take_samples(apu)
    pcm
  end

  defp complex_audio(renderer) do
    apu =
      Enum.reduce(0..15, APU.new(model: :cgb) |> APU.set_renderer(renderer), fn index, apu ->
        APU.write(apu, 0xFF30 + index, rem(index * 29, 256))
      end)
      |> APU.write(0xFF26, 0x80)
      |> APU.write(0xFF10, 0x23)
      |> APU.write(0xFF11, 0x80)
      |> APU.write(0xFF12, 0xA2)
      |> APU.write(0xFF13, 0x40)
      |> APU.write(0xFF14, 0x87)
      |> APU.write(0xFF16, 0x40)
      |> APU.write(0xFF17, 0x73)
      |> APU.write(0xFF18, 0xA0)
      |> APU.write(0xFF19, 0x86)
      |> APU.write(0xFF1A, 0x80)
      |> APU.write(0xFF1C, 0x40)
      |> APU.write(0xFF1D, 0x70)
      |> APU.write(0xFF1E, 0x85)
      |> APU.write(0xFF21, 0x92)
      |> APU.write(0xFF22, 0x35)
      |> APU.write(0xFF23, 0x80)
      |> APU.write(0xFF24, 0x75)
      |> APU.write(0xFF25, 0xFF)
      |> APU.tick(31_337)
      |> APU.write(0xFF18, 0xD2)
      |> APU.write(0xFF19, 0x82)
      |> APU.tick(83_111)

    {count, pcm, _apu} = APU.take_samples(apu)
    {count, pcm}
  end
end
