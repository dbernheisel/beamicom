defmodule BeamicomStream.PlayerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true

  alias Beamicom.GB.DiagnosticROM
  alias Beamicom.Host.{Output, VideoFrame}
  alias BeamicomStream.AV.VideoSource
  alias BeamicomStream.Player

  test "runs a CGB ROM through the dynamic RGB/stereo pipeline" do
    rom =
      Path.join(System.tmp_dir!(), "beamicom-stream-#{System.unique_integer([:positive])}.gbc")

    File.write!(rom, DiagnosticROM.build_cgb())
    on_exit(fn -> File.rm(rom) end)
    port = 24_000 + rem(System.unique_integer([:positive]), 10_000)

    assert {:ok, player} = Player.start_link(rom: rom, target: {{127, 0, 0, 1}, port})

    assert {:ok, other_player} =
             Player.start_link(rom: rom, target: {{127, 0, 0, 1}, port + 4})

    Process.unlink(player)
    Process.unlink(other_player)
    ref = Process.monitor(player)
    other_ref = Process.monitor(other_player)

    try do
      assert %{system: :gbc, controls: %{1 => []}} = Player.status(player)
      assert %{system: :gbc, controls: %{1 => []}} = Player.status(other_player)
      assert :ok = Player.button_event(player, :a, :down)
      assert %{controls: %{1 => [:a]}} = Player.status(player)
      %{runtime: runtime} = :sys.get_state(player)
      assert BeamicomStream.Runtime.snapshot(runtime).bus.buttons == 0x10
      assert {:error, :invalid_buttons} = Player.set_buttons(player, 2, [:a])
      assert BeamicomStream.Runtime.snapshot(runtime).bus.buttons == 0x10
      refute_receive {:DOWN, ^ref, :process, ^player, _reason}, 500
      refute_receive {:DOWN, ^other_ref, :process, ^other_player, _reason}, 0
    after
      if Process.alive?(player), do: GenServer.stop(player)
      if Process.alive?(other_player), do: GenServer.stop(other_player)
    end
  end

  test "runs a DMG ROM through native shade conversion" do
    rom = temporary_rom("gb", DiagnosticROM.build())
    port = 34_000 + rem(System.unique_integer([:positive]), 5_000)

    assert {:ok, player} = Player.start_link(rom: rom, target: {{127, 0, 0, 1}, port})
    Process.unlink(player)

    try do
      %{output: output} = :sys.get_state(player)

      assert %VideoFrame{pixel_format: {:native, :dmg_shade_index}} =
               frame =
               wait_for_video(output)

      assert byte_size(VideoSource.rgb_payload(frame)) == 160 * 144 * 3
    after
      if Process.alive?(player), do: GenServer.stop(player)
    end
  end

  test "malformed Game Boy media returns its load error and cleans private AV children" do
    rom = temporary_rom("gbc", "bad")
    before = av_processes()
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:rom_too_small, 0x150, 3}} =
               Player.start_link(rom: rom, target: {{127, 0, 0, 1}, 39_000})

      assert eventually(fn -> av_processes() == before end)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp temporary_rom(extension, media) do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-stream-#{System.unique_integer([:positive])}.#{extension}"
      )

    File.write!(path, media)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp wait_for_video(output, attempts \\ 100)
  defp wait_for_video(_output, 0), do: flunk("player did not publish a video frame")

  defp wait_for_video(output, attempts) do
    case Output.latest_video(output) do
      nil ->
        Process.sleep(10)
        wait_for_video(output, attempts - 1)

      frame ->
        frame
    end
  end

  defp av_processes do
    modules = [Beamicom.Host.Output, Membrane.Core.Pipeline, Membrane.Core.Pipeline.Supervisor]

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          case dictionary[:"$initial_call"] do
            {module, :init, 1} -> module in modules
            _other -> false
          end

        nil ->
          false
      end
    end)
    |> MapSet.new()
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
