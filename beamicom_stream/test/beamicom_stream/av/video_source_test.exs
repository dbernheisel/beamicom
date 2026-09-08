defmodule BeamicomStream.AV.VideoSourceTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.{Framebuffer, Output}
  alias BeamicomStream.AV.VideoSource

  test "timestamps the latest frame when a coalesced notification is older" do
    frame = %Framebuffer{
      number: 42,
      width: 1,
      height: 1,
      pixels: <<0>>,
      palette: <<0::size(32 * 8)>>
    }

    Output.publish(frame)
    _state = :sys.get_state(Output)

    assert {[buffer: {:output, %Membrane.Buffer{} = buffer}], %{owner: nil}} =
             VideoSource.handle_info({:frame, 1}, nil, %{owner: nil})

    assert buffer.payload == <<84, 84, 84>>
    assert buffer.pts == 42 * round(1_000_000_000 / 60.0988)
  end
end
