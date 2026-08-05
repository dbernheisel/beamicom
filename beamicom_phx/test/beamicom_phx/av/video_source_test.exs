defmodule BeamicomPhx.AV.VideoSourceTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing
  alias Beamicom.NES.Framebuffer

  @width 256
  @height 240

  defp blank_frame(number) do
    %Framebuffer{
      number: number,
      pixels: :binary.copy(<<0>>, @width * @height),
      palette: :binary.copy(<<0>>, 32)
    }
  end

  test "emits an RGB RawVideo buffer for each published frame" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:src, BeamicomPhx.AV.VideoSource)
          |> child(:sink, Testing.Sink)
        ]
      )

    assert_receive {Membrane.Testing.Pipeline, ^pipeline, :play}
    assert_receive {Membrane.Testing.Pipeline, ^pipeline, {:handle_child_playing, :src}}

    # handle_child_playing can arrive before handle_playing's subscribe completes;
    # wait for the subscription so publish doesn't race ahead of it.
    assert BeamicomPhx.OutputSync.await_subscriber(:video) == :ok
    Beamicom.NES.Output.publish(blank_frame(1))

    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{
      width: @width,
      height: @height,
      pixel_format: :RGB
    })

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload})
    # 3 bytes/pixel (RGB), all black for a zero frame.
    assert byte_size(payload) == @width * @height * 3

    Testing.Pipeline.terminate(pipeline)
  end
end
