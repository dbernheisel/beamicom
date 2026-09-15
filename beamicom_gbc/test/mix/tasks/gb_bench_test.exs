defmodule Mix.Tasks.Gb.BenchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Beamicom.GB.{DiagnosticROM, ShareImage, System}

  test "replays a share-image state against its matching ROM" do
    root =
      Path.join(
        Elixir.System.tmp_dir!(),
        "beamicom-gb-bench-#{:erlang.unique_integer([:positive])}"
      )

    rom_path = Path.join(root, "diagnostic.gbc")
    state_path = Path.join(root, "gameplay.png")
    rom = DiagnosticROM.build_cgb()
    File.mkdir_p!(root)
    File.write!(rom_path, rom)

    {:ok, machine} = System.load(rom)
    {machine, [video, _audio]} = System.run_slice(machine)
    state = ShareImage.to_png(machine, video.data)
    File.write!(state_path, state)

    on_exit(fn -> File.rm_rf(root) end)
    Mix.Task.reenable("gb.bench")

    output =
      capture_io(fn ->
        Mix.Tasks.Gb.Bench.run([
          rom_path,
          "--state",
          state_path,
          "--frames",
          "2",
          "--repeats",
          "2"
        ])
      end)

    assert output =~ "start_frame: 1"
    assert output =~ "median_fps:"
    assert output =~ sha256(state)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
