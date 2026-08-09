defmodule Mix.Tasks.Beamicom.V4l2Test do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Beamicom.V4l2

  test "parses launcher options" do
    assert {:ok, opts} =
             V4l2.parse_args([
               "game.nes",
               "--socket",
               "/tmp/controller.sock",
               "--scale",
               "4",
               "--input",
               "/dev/input/event7",
               "--no-audio"
             ])

    assert opts.rom == Path.expand("game.nes")
    assert opts.socket == "/tmp/controller.sock"
    assert opts.input == "/dev/input/event7"
    assert opts.player_options[:scale] == 4
    refute opts.player_options[:audio]
  end

  test "rejects invalid rendering options" do
    assert V4l2.parse_args(["game.nes", "--fps", "0"]) == {:error, "--fps must be positive"}

    assert V4l2.parse_args(["game.nes", "--scale", "9"]) ==
             {:error, "--scale must be between 1 and 8"}
  end
end
