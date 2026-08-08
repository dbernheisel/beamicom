defmodule BeamicomStream.CLITest do
  use ExUnit.Case, async: true

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
end
