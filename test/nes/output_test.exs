defmodule Beamicom.NES.OutputTest do
  # Shares the application-started Output (global name + ETS table).
  use ExUnit.Case, async: false

  alias Beamicom.NES.{Framebuffer, Output, Runtime}

  test "publish stores the latest frame and notifies subscribers" do
    Output.subscribe()
    frame = %Framebuffer{number: 7, pixels: <<>>, palette: <<>>}
    Output.publish(frame)

    assert_receive {:frame, 7}
    assert %Framebuffer{number: 7} = Output.latest()
  end

  test "audio samples are streamed to subscribers" do
    Output.subscribe()
    Output.publish_audio([1, 2, 3])
    assert_receive {:audio, [1, 2, 3]}
  end

  @tag :tmp_dir
  test "runtime loads a ROM and publishes frames to the hub", %{tmp_dir: tmp} do
    # Minimal NROM: reset vector -> $8000, where `JMP $8000` spins forever. The
    # PPU still produces frames while the CPU loops.
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>

    rom =
      <<"NES", 0x1A, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>> <> prg <> <<0::size(8192 * 8)>>

    path = Path.join(tmp, "spin.nes")
    File.write!(path, rom)

    Output.subscribe()
    start_supervised!({Runtime, rom: path, pace: false, name: :test_runtime})

    assert_receive {:frame, n} when is_integer(n) and n >= 0, 2000
    assert %Framebuffer{width: 256, height: 240} = Output.latest()
  end
end
