defmodule BeamicomStream.RuntimeTest do
  use ExUnit.Case, async: true

  alias Beamicom.GB.DiagnosticROM
  alias Beamicom.Host.{AudioChunk, Input, Output, VideoFrame}
  alias BeamicomStream.Runtime

  test "runs a CGB core through neutral output and accepts handheld input" do
    output = start_supervised!({Output, name: nil})
    assert :ok = Output.subscribe(output)

    runtime =
      start_supervised!(
        {Runtime,
         system: Beamicom.GB.System,
         media: DiagnosticROM.build_cgb(),
         output: output,
         name: nil,
         load_options: []}
      )

    assert_receive {:video_frame, :gbc, 0}, 1_000

    assert %VideoFrame{width: 160, height: 144, pixel_format: :rgb24} =
             Output.latest_video(output)

    assert_receive {:audio_chunk,
                    %AudioChunk{
                      system: :gbc,
                      channels: 2,
                      sample_rate: 44_100,
                      sample_format: :s16le
                    }},
                   1_000

    assert :ok = Runtime.set_input(runtime, Input.new(1, [:right, :a]))
    machine = Runtime.snapshot(runtime)
    assert machine.bus.buttons == 0x11
  end

  test "reports media load failures as normal GenServer start errors" do
    output = start_supervised!({Output, name: nil})
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:rom_too_small, 0x150, 3}} =
               Runtime.start_link(
                 system: Beamicom.GB.System,
                 media: "bad",
                 output: output,
                 name: nil
               )
    after
      Process.flag(:trap_exit, previous)
    end
  end
end
