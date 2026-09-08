defmodule BeamicomV4L2.RuntimeTest do
  use ExUnit.Case, async: false

  alias Beamicom.GB.{DiagnosticROM, System}
  alias Beamicom.Host.{AudioChunk, Input, Output, VideoFrame}
  alias BeamicomV4L2.Runtime

  test "publishes CGB RGB and stereo audio and accepts only port one input" do
    {:ok, machine} = System.load(DiagnosticROM.build_cgb())
    output = start_supervised!({Output, []})
    :ok = Output.subscribe(output)

    runtime =
      start_supervised!({Runtime, machine: machine, output: output, pace: true})

    assert_receive {:video_frame, :gbc, _number}, 2_000

    assert %VideoFrame{width: 160, height: 144, pixel_format: :rgb24} =
             Output.latest_video(output)

    assert_receive {:audio_chunk,
                    %AudioChunk{
                      system: :gbc,
                      channels: 2,
                      sample_rate: 44_100,
                      sample_format: :s16le
                    }},
                   2_000

    Runtime.set_input(runtime, Input.new(1, [:a, :right]))
    assert Runtime.snapshot(runtime).bus.buttons == 0x11
    Runtime.set_input(runtime, Input.new(2, [:b]))
    assert Runtime.snapshot(runtime).bus.buttons == 0x11
  end
end
