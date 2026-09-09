defmodule Beamicom.Host.RuntimeTest do
  use ExUnit.Case, async: false

  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities, Output, Runtime, VideoFrame}

  @heap_words 65_536

  defmodule TestSystem do
    def id, do: :runtime_test

    def capabilities do
      %{
        media_extensions: [".test"],
        input: InputCapabilities.new(%{1 => [:a]}),
        video: %{width: 1, height: 1, frame_rate: 10.0},
        audio: %{sample_rate: 8_000, channels: 1, sample_format: :s16le}
      }
    end

    def load(media, options), do: {:ok, %{number: byte_size(media), input: nil, options: options}}

    def run_slice(%{number: number} = machine) do
      video = %VideoFrame{
        system: :runtime_test,
        number: number,
        width: 1,
        height: 1,
        pixel_format: :rgb24,
        data: <<number::24>>
      }

      audio = %AudioChunk{
        system: :runtime_test,
        sample_rate: 8_000,
        channels: 1,
        sample_format: :s16le,
        frame_count: 1,
        data: <<number::signed-little-16>>
      }

      {%{machine | number: number + 1}, [video, audio]}
    end

    def set_input(machine, %Input{} = input), do: %{machine | input: input}
  end

  test "loads, publishes typed output, accepts input, and uses the realtime heap profile" do
    output = start_supervised!({Output, name: nil})
    :ok = Output.subscribe(output)

    runtime =
      start_supervised!(
        {Runtime,
         system: TestSystem, media: "abc", load_options: [boot: :fast], output: output, name: nil}
      )

    assert_receive {:video_frame, :runtime_test, 3}, 200
    assert %VideoFrame{number: 3} = Output.latest_video(output)
    assert_receive {:audio_chunk, %AudioChunk{frame_count: 1}}, 200

    assert :ok = Runtime.set_input(runtime, Input.new(1, [:a]))
    assert %Input{port: 1, controls: controls} = Runtime.snapshot(runtime).input
    assert MapSet.equal?(controls, MapSet.new([:a]))
    assert Runtime.snapshot(runtime).options == [boot: :fast]

    assert {:priority, :high} = Process.info(runtime, :priority)
    assert {:min_heap_size, heap} = Process.info(runtime, :min_heap_size)
    assert {:min_bin_vheap_size, binary_heap} = Process.info(runtime, :min_bin_vheap_size)
    assert heap >= @heap_words
    assert binary_heap >= @heap_words
  end

  test "pause, step, and resume retain one generation-tagged timer chain" do
    output = start_supervised!({Output, name: nil})
    :ok = Output.subscribe_video(output)

    runtime =
      start_supervised!(
        {Runtime,
         system: TestSystem, machine: %{number: 0, input: nil, options: []}, output: output}
      )

    assert_receive {:video_frame, :runtime_test, 0}, 200
    assert %VideoFrame{number: 0} = Output.latest_video(output)

    Process.sleep(10)
    Runtime.pause(runtime)
    assert %{paused: true, timer: nil} = :sys.get_state(runtime)

    Runtime.step(runtime)
    assert_receive {:video_frame, :runtime_test, 1}, 100
    assert %VideoFrame{number: 1} = Output.latest_video(output)
    refute_receive {:video_frame, :runtime_test, _number}, 110

    Runtime.resume(runtime)
    assert_receive {:video_frame, :runtime_test, 2}, 100
    assert %VideoFrame{number: 2} = Output.latest_video(output)
    refute_receive {:video_frame, :runtime_test, _number}, 50
    assert_receive {:video_frame, :runtime_test, 3}, 100
  end
end
