defmodule BeamicomPhx.AV.AudioSourceTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  test "emits an s16le RawAudio buffer for each published sample chunk" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:src, BeamicomPhx.AV.AudioSource)
          |> child(:sink, Testing.Sink)
        ]
      )

    assert_receive {Membrane.Testing.Pipeline, ^pipeline, :play}
    assert_receive {Membrane.Testing.Pipeline, ^pipeline, {:handle_child_playing, :src}}

    # handle_child_playing can arrive before handle_playing's subscribe completes;
    # wait for the subscription so publish doesn't race ahead of it.
    assert BeamicomPhx.OutputSync.await_subscriber(:audio) == :ok
    pcm = <<0::signed-little-16, 100::signed-little-16, -100::signed-little-16>>
    Beamicom.NES.Output.publish_audio(3, pcm)
    Beamicom.NES.Output.publish_audio(2, <<200::signed-little-16, -200::signed-little-16>>)

    assert_sink_stream_format(pipeline, :sink, %Membrane.RawAudio{
      channels: 1,
      sample_rate: 44_100,
      sample_format: :s16le
    })

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload, pts: 0})
    assert payload == pcm

    expected_pts = div(3 * 1_000_000_000, 44_100)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
      payload: <<200::signed-little-16, -200::signed-little-16>>,
      pts: ^expected_pts
    })

    Testing.Pipeline.terminate(pipeline)
  end
end
