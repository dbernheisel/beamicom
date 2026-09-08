defmodule BeamicomStream.CLITest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Beamicom.Stream

  test "parses focused local-player options" do
    assert {:ok, opts} =
             Stream.parse_args([
               "game.nes",
               "--host",
               "127.0.0.2",
               "--port",
               "6000",
               "--controller",
               "2",
               "--no-player",
               "--ffplay",
               "/tmp/fake-ffplay"
             ])

    assert opts.host == {127, 0, 0, 2}
    assert opts.port == 6_000
    assert opts.system == :nes
    assert opts.audio_channels == 1
    assert opts.controller == 2
    refute opts.player?
    assert opts.ffplay == "/tmp/fake-ffplay"
  end

  test "rejects invalid ports and controller numbers" do
    assert {:error, "--port must be between 1 and 65533"} =
             Stream.parse_args(["game.nes", "--port", "65534"])

    assert {:error, "--controller must be 1 or 2"} =
             Stream.parse_args(["game.nes", "--controller", "3"])
  end

  test "selects GBC stereo output and enforces its single input port" do
    assert {:ok, opts} = Stream.parse_args(["game.gbc", "--no-player"])
    assert {opts.system, opts.audio_channels, opts.controller} == {:gbc, 2, 1}

    assert {:error, "controller 2 is not supported for gbc"} =
             Stream.parse_args(["game.gb", "--controller", "2"])

    assert {:error, "unsupported ROM extension: .smc"} = Stream.parse_args(["game.smc"])
  end

  test "removes the temporary SDP when ffplay cannot start" do
    rom =
      Path.join(
        System.tmp_dir!(),
        "beamicom-stream-cli-#{System.unique_integer([:positive])}.nes"
      )

    File.write!(rom, "not reached")
    on_exit(fn -> File.rm(rom) end)
    before = temporary_sdps()

    assert_raise Mix.Error, ~r/executable not found/, fn ->
      Stream.run([rom, "--ffplay", "/missing/beamicom-ffplay"])
    end

    assert temporary_sdps() == before
  end

  defp temporary_sdps do
    System.tmp_dir!()
    |> Path.join("beamicom-stream-*.sdp")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
