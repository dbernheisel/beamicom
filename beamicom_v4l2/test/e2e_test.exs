defmodule BeamicomV4L2E2ETest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.{Output, PNG, Palette}

  @moduletag :e2e
  @scale 3

  test "runs a real ROM, maps controls, and streams it through V4L2" do
    repository = Path.expand("../..", __DIR__)
    framebuffer = System.get_env("FRAMEBUFFER", "/dev/fb0")
    output = System.get_env("VIDEO_OUTPUT", "/dev/video-beamicom")

    rom =
      System.get_env(
        "BEAMICOM_ROM",
        Path.join(repository, "beamicom_phx/test/support/fixtures/01.basics.nes")
      )
      |> Path.expand()

    temporary =
      Path.join(System.tmp_dir!(), "beamicom-v4l2-rom-#{System.unique_integer([:positive])}")

    rendered = temporary <> "-rendered.png"
    captured = temporary <> "-captured.png"
    on_exit(fn -> Enum.each([rendered, captured], &File.rm/1) end)

    assert {:ok, %{type: :device}} = File.stat(framebuffer)
    assert {:ok, %{type: :device}} = File.stat(output)
    assert {:ok, %{type: :regular}} = File.stat(rom)

    assert {:ok, player} =
             BeamicomV4L2.start_link(
               rom: rom,
               framebuffer: framebuffer,
               output: output,
               fps: 60,
               scale: @scale,
               audio: false,
               name: BeamicomV4L2.Player
             )

    assert eventually(fn -> BeamicomV4L2.status(player).frame >= 60 end)
    assert BeamicomV4L2.status(player).scale == @scale

    assert :ok = BeamicomV4L2.key_down("x")
    assert :a in BeamicomV4L2.status(player).controls[1]
    assert :ok = BeamicomV4L2.key_up("x")
    refute :a in BeamicomV4L2.status(player).controls[1]

    emulator_frame = Output.latest()

    File.write!(
      rendered,
      PNG.encode(
        emulator_frame.width * @scale,
        emulator_frame.height * @scale,
        upscale(Palette.to_rgb(emulator_frame), emulator_frame.width, @scale)
      )
    )

    # Read the scaled NES region continuously published by BeamicomV4L2.Player.
    assert_command("ffmpeg", [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-f",
      "v4l2",
      "-i",
      output,
      "-frames:v",
      "1",
      captured
    ])

    assert File.stat!(captured).size > 0

    # YUYV 4:2:2 is chroma-subsampled and the emulator continues running during
    # capture, so use a conservative perceptual threshold instead of byte identity.
    comparison =
      assert_command("ffmpeg", [
        "-hide_banner",
        "-i",
        rendered,
        "-i",
        captured,
        "-lavfi",
        "psnr",
        "-frames:v",
        "1",
        "-f",
        "null",
        "-"
      ])

    assert [_, average] = Regex.run(~r/average:([0-9.]+)/, comparison)
    assert String.to_float(average) > 20.0
    assert :ok = BeamicomV4L2.stop(player)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end

  defp assert_command(command, arguments) do
    {output, status} = System.cmd(command, arguments, stderr_to_stdout: true)
    assert status == 0, "#{command} failed with status #{status}:\n#{output}"
    output
  end

  defp upscale(rgb, width, scale) do
    scaled_row_size = width * 3 * scale
    scaled_rows = for <<pixel::binary-size(3) <- rgb>>, into: <<>>, do: :binary.copy(pixel, scale)

    for <<row::binary-size(^scaled_row_size) <- scaled_rows>>,
      into: <<>>,
      do: :binary.copy(row, scale)
  end
end
