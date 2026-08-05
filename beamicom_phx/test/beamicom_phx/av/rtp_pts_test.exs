defmodule BeamicomPhx.AV.RtpPtsTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  test "sets pts from the RTP timestamp (ticks -> ns), even when incoming pts is nil" do
    # RTP.Parser output: header timestamp in metadata.rtp.timestamp, pts nil.
    buffers = [
      %Membrane.Buffer{payload: <<1, 2, 3>>, pts: nil, metadata: %{rtp: %{timestamp: 90_000}}}
    ]

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:src, %Testing.Source{output: buffers, stream_format: %Membrane.RTP{}})
          |> child(:pts, %BeamicomPhx.AV.RtpPts{clock_rate: 90_000})
          |> child(:sink, Testing.Sink)
        ]
      )

    # 90_000 ticks at 90 kHz == 1 second == 1_000_000_000 ns
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: 1_000_000_000})
    Testing.Pipeline.terminate(pipeline)
  end
end
