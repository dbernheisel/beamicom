defmodule BeamicomPhx.EmulatorTest do
  use ExUnit.Case, async: false
  # Runs the real NES Runtime (publishes into the shared Beamicom.NES.Output), so
  # it's excluded from the default suite to avoid contaminating the source tests.
  @moduletag :integration

  @rom "test/support/fixtures/01.basics.nes"

  alias Beamicom.GB.DiagnosticROM
  alias Beamicom.Host.{Output, VideoFrame}
  alias Beamicom.NES.Output, as: NESOutput
  alias BeamicomPhx.{Emulator, Saves}
  alias BeamicomStream.Runtime, as: GBRuntime

  setup do
    previous_saves_dir = Application.fetch_env!(:beamicom_phx, :saves_dir)
    saves_dir = temporary_directory("saves")
    Application.put_env(:beamicom_phx, :saves_dir, saves_dir)

    on_exit(fn -> Application.put_env(:beamicom_phx, :saves_dir, previous_saves_dir) end)
    on_exit(&Emulator.stop/0)
    {:ok, saves_dir: saves_dir}
  end

  test "load/1 starts a Runtime that produces frames; stop/0 tears it down" do
    refute Emulator.loaded?()
    NESOutput.subscribe_video()

    assert :ok = Emulator.load(@rom)
    assert Emulator.loaded?()
    assert Emulator.system() == :nes

    assert_receive {:frame, _number}, 1_000
    assert %Beamicom.NES.Framebuffer{} = NESOutput.latest()

    assert :ok = Emulator.stop()
    refute Emulator.loaded?()
  end

  test "loads CGB video/stereo, accepts only port one, and round-trips a save", %{
    saves_dir: saves_dir
  } do
    rom = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.subscribe()
    assert :ok = Emulator.load(rom)

    assert_receive {:emulator_profile, profile}
    assert profile.system == :gbc
    assert {profile.video.width, profile.video.height} == {160, 144}
    assert profile.audio.channels == 2
    assert is_pid(profile.output)

    assert :ok = Output.subscribe_video(profile.output)
    assert_receive {:video_frame, :gbc, _number}, 1_000
    assert %VideoFrame{pixel_format: :rgb24} = Output.latest_video(profile.output)

    %{session: %{runtime: runtime}} = :sys.get_state(Emulator)
    before = GBRuntime.snapshot(runtime).bus.buttons
    assert {:error, :unsupported_port} = Emulator.press(2, [:right, :a])
    assert GBRuntime.snapshot(runtime).bus.buttons == before

    assert :ok = Emulator.press(1, [:right, :a])
    assert GBRuntime.snapshot(runtime).bus.buttons == 0x11

    assert {:ok, save_url} = Saves.capture()
    assert [^save_url] = Saves.list()
    save_path = Path.join(saves_dir, Path.basename(save_url))
    assert {:ok, saved_machine} = Beamicom.GB.ShareImage.load_image(File.read!(save_path))
    assert saved_machine.model == :cgb
    assert :ok = Saves.load(save_url)
    assert Emulator.system() == :gbc

    assert {:ok, second_url} = Saves.capture()
    refute second_url == save_url
    assert Enum.sort(Saves.list()) == Enum.sort([save_url, second_url])
    assert File.exists?(Path.join(saves_dir, Path.basename(second_url)))

    output_ref = Process.monitor(profile.output)
    assert :ok = Emulator.stop()
    assert_receive {:DOWN, ^output_ref, :process, _, :shutdown}
  end

  test "a malformed replacement preserves the running session" do
    rom = temporary_rom("gb", DiagnosticROM.build())
    bad = temporary_rom("gbc", "bad")
    assert :ok = Emulator.load(rom)

    before = Emulator.profile()
    %{session: %{runtime: runtime}} = :sys.get_state(Emulator)

    assert {:error, {:rom_too_small, 0x150, 3}} = Emulator.load(bad)
    assert Emulator.profile() == before
    assert %{session: %{runtime: ^runtime}} = :sys.get_state(Emulator)
  end

  test "save loading identifies and switches between GBC and legacy NES images", %{
    saves_dir: saves_dir
  } do
    gbc = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.load(gbc)
    gbc_output = Emulator.profile().output
    assert :ok = Output.subscribe_video(gbc_output)
    assert_receive {:video_frame, :gbc, _number}, 1_000
    assert {:ok, gbc_save} = Saves.capture()
    gbc_png = File.read!(Path.join(saves_dir, Path.basename(gbc_save)))
    {width, height, rgb} = Beamicom.GB.PNG.decode_rgb(gbc_png)
    offset = (width + 1) * 3
    <<head::binary-size(^offset), byte, rest::binary>> = rgb
    damaged_rgb = <<head::binary, 255 - byte, rest::binary>>
    {:ok, trailer} = Beamicom.GB.ShareImage.get_trailer(gbc_png)

    damaged_gbc =
      Beamicom.GB.PNG.encode_rgb(width, height, damaged_rgb)
      |> Beamicom.GB.ShareImage.put_trailer(trailer)

    File.write!(Path.join(saves_dir, "damaged-gbc.png"), damaged_gbc)
    assert {:error, :undecodable} = Saves.load("/saves/damaged-gbc.png")

    NESOutput.subscribe_video()
    assert :ok = Emulator.load(@rom)
    assert_receive {:frame, _number}, 1_000
    assert {:ok, nes_save} = Saves.capture()

    assert :ok = Saves.load(gbc_save)
    assert Emulator.system() == :gbc
    assert :ok = Saves.load(nes_save)
    assert Emulator.system() == :nes
  end

  test "save capture reports filesystem errors without publishing a gallery change" do
    rom = temporary_rom("gbc", DiagnosticROM.build_cgb())
    blocked_parent = temporary_rom("blocked", "not a directory")
    Application.put_env(:beamicom_phx, :saves_dir, Path.join(blocked_parent, "saves"))

    assert :ok = Saves.subscribe()
    assert :ok = Emulator.load(rom)
    output = Emulator.profile().output
    assert :ok = Output.subscribe_video(output)
    assert_receive {:video_frame, :gbc, _number}, 1_000

    assert {:error, :enotdir} = Saves.capture()
    refute_receive :saves_changed
  end

  test "same-family replacement keeps output and encoder epoch" do
    first = temporary_rom("gb", DiagnosticROM.build())
    second = temporary_rom("gb", DiagnosticROM.build())
    assert :ok = Emulator.subscribe()
    assert :ok = Emulator.load(first)
    assert_receive {:emulator_profile, first_profile}

    assert :ok = Emulator.load(second)
    assert Emulator.profile().output == first_profile.output
    refute_receive {:emulator_profile, _profile}
  end

  test "load starts the configured RTP broadcast" do
    previous_target = Application.get_env(:beamicom_phx, :rtp_target)
    Application.put_env(:beamicom_phx, :rtp_target, {{127, 0, 0, 1}, 15_000})

    on_exit(fn ->
      if is_nil(previous_target) do
        Application.delete_env(:beamicom_phx, :rtp_target)
      else
        Application.put_env(:beamicom_phx, :rtp_target, previous_target)
      end
    end)

    rom = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.load(rom)

    assert %{session: %{broadcast: %{supervisor: supervisor, pipeline: pipeline}}} =
             :sys.get_state(Emulator)

    assert is_pid(supervisor)
    assert is_pid(pipeline)
  end

  test "independent browser sources aggregate held input and disconnect releases it" do
    rom = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.load(rom)
    parent = self()

    first =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:pressed, self(), Emulator.press(1, [:a])})
             receive do: (:stop -> :ok)
           end},
          id: :first_input_owner
        )
      )

    assert_receive {:pressed, first_pid, :ok}

    second =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:pressed, self(), Emulator.press(1, [:right])})
             receive do: (:stop -> :ok)
           end},
          id: :second_input_owner
        )
      )

    assert_receive {:pressed, second_pid, :ok}
    assert first == first_pid
    assert second == second_pid
    assert eventually_buttons(0x11)

    first_ref = Process.monitor(first)
    send(first, :stop)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}
    assert eventually_buttons(0x01)

    second_ref = Process.monitor(second)
    send(second, :stop)
    assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}
    assert eventually_buttons(0x00)
  end

  test "remote held state keeps one logical seat across GBC and NES transitions" do
    gbc = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.load(gbc)
    assert :ok = Emulator.press(1, [:right])
    assert :ok = Emulator.press_remote([:a])

    %{session: %{runtime: gbc_runtime}} = :sys.get_state(Emulator)
    assert GBRuntime.snapshot(gbc_runtime).bus.buttons == 0x11

    assert :ok = Emulator.load(@rom)
    %{session: %{runtime: nes_runtime}} = :sys.get_state(Emulator)
    {console, _frame} = Beamicom.NES.Runtime.snapshot(nes_runtime)
    assert console.bus.pad1.buttons == Beamicom.NES.Controllers.mask([:right])
    assert console.bus.pad2.buttons == Beamicom.NES.Controllers.mask([:a])

    assert :ok = Emulator.load(gbc)
    %{session: %{runtime: gbc_runtime}} = :sys.get_state(Emulator)
    assert GBRuntime.snapshot(gbc_runtime).bus.buttons == 0x11

    assert :ok = Emulator.press_remote([])
    assert GBRuntime.snapshot(gbc_runtime).bus.buttons == 0x01
  end

  test "rom_name selects the core while reading a Phoenix-owned upload path" do
    upload_path = temporary_rom("upload", DiagnosticROM.build_cgb())

    assert :ok = Emulator.load(upload_path, rom_name: "safe-name.gbc")
    assert %{system: :gbc, rom_name: "safe-name.gbc"} = Emulator.profile()
  end

  test "runtime failure tears down its private GBC output" do
    rom = temporary_rom("gbc", DiagnosticROM.build_cgb())
    assert :ok = Emulator.load(rom)
    assert :ok = Emulator.press(1, [:a])
    %{session: %{runtime: runtime, output: output}} = :sys.get_state(Emulator)
    output_ref = Process.monitor(output)

    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^output_ref, :process, ^output, _reason}, 1_000
    refute Emulator.loaded?()
    assert %{inputs: inputs, input_monitors: monitors} = :sys.get_state(Emulator)
    assert inputs == %{}
    assert monitors == %{}

    assert :ok = Emulator.load(rom)
    %{session: %{runtime: runtime}} = :sys.get_state(Emulator)
    assert GBRuntime.snapshot(runtime).bus.buttons == 0
  end

  defp temporary_rom(extension, media) do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-phx-#{System.unique_integer([:positive, :monotonic])}.#{extension}"
      )

    File.write!(path, media)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp temporary_directory(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-phx-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp eventually_buttons(expected, attempts \\ 100)

  defp eventually_buttons(_expected, 0), do: false

  defp eventually_buttons(expected, attempts) do
    %{session: %{runtime: runtime}} = :sys.get_state(Emulator)

    if GBRuntime.snapshot(runtime).bus.buttons == expected,
      do: true,
      else: eventually_buttons(expected, attempts - 1)
  end
end
