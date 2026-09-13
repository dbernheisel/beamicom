defmodule Beamicom.GB.Nx.PPURendererTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.{APU, DiagnosticROM, SaveState, System}

  setup do
    previous = Application.get_env(:beamicom_gbc, :ppu_renderer, :native)
    previous_apu = Application.get_env(:beamicom_gbc, :apu_renderer, :native)

    on_exit(fn ->
      Application.put_env(:beamicom_gbc, :ppu_renderer, previous)
      Application.put_env(:beamicom_gbc, :apu_renderer, previous_apu)
    end)
  end

  for {model, media} <- [dmg: DiagnosticROM.build(), cgb: DiagnosticROM.build_cgb()] do
    test "#{model} frame composition is pixel-exact" do
      media = unquote(Macro.escape(media))
      Application.put_env(:beamicom_gbc, :ppu_renderer, :native)
      Application.put_env(:beamicom_gbc, :apu_renderer, :native)
      {:ok, native} = System.load(media, [])
      {_native, [native_video, native_audio]} = System.run_slice(native)

      Application.put_env(:beamicom_gbc, :ppu_renderer, Beamicom.GB.Nx.PPURenderer)
      Application.put_env(:beamicom_gbc, :apu_renderer, Beamicom.GB.Nx.APUBlockRenderer)
      {:ok, accelerated} = System.load(media, [])
      {_accelerated, [video, audio]} = System.run_slice(accelerated)

      assert video.data == native_video.data
      assert audio.data == native_audio.data
      assert video.pixel_format == native_video.pixel_format
    end
  end

  test "Nx-backed machines survive save and restore at a frame boundary" do
    Application.put_env(:beamicom_gbc, :ppu_renderer, Beamicom.GB.Nx.PPURenderer)
    Application.put_env(:beamicom_gbc, :apu_renderer, Beamicom.GB.Nx.APUBlockRenderer)
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

  test "application boundary enables and disables the optional renderer" do
    assert :ok = Beamicom.GB.Nx.disable()
    assert Application.get_env(:beamicom_gbc, :ppu_renderer) == :native
    assert Application.get_env(:beamicom_gbc, :apu_renderer) == :native
    assert :ok = Beamicom.GB.Nx.enable()
    assert Application.get_env(:beamicom_gbc, :ppu_renderer) == Beamicom.GB.Nx.PPURenderer

    assert Application.get_env(:beamicom_gbc, :apu_renderer) ==
             Beamicom.GB.Nx.APUBlockRenderer
  end

  defp audible_audio(renderer) do
    Application.put_env(:beamicom_gbc, :apu_renderer, renderer)

    apu =
      APU.new(model: :cgb)
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
end
