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

  test "audio PCM binaries are streamed to subscribers with their sample count" do
    Output.subscribe()
    pcm = <<1::signed-little-16, 2::signed-little-16, 3::signed-little-16>>
    Output.publish_audio(3, pcm)
    assert_receive {:audio, 3, ^pcm}
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

    assert_receive {:audio, sample_count, pcm}
                   when is_integer(sample_count) and sample_count > 0 and is_binary(pcm),
                   2000

    assert byte_size(pcm) == sample_count * 2
    assert_receive {:frame, n} when is_integer(n) and n >= 1, 2000
    assert_receive {:audio, sample_count, pcm} when is_binary(pcm), 2000
    assert sample_count in 700..750
    assert byte_size(pcm) == sample_count * 2
    assert %Framebuffer{width: 256, height: 240} = Output.latest()

    assert :ok = Runtime.set_enhancement(:test_runtime, :hide_horizontal_overscan, true)
    assert :ok = Runtime.set_enhancement(:test_runtime, :unlimited_sprites, true)
    {console, _frame} = Runtime.snapshot(:test_runtime)
    assert console.bus.ppu.hide_horizontal_overscan
    assert console.bus.ppu.unlimited_sprites

    assert {:error, :invalid_enhancement} =
             Runtime.set_enhancement(:test_runtime, :unknown, true)
  end
end
