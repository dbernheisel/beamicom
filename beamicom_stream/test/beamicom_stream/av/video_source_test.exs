defmodule BeamicomStream.AV.VideoSourceTest do
  use ExUnit.Case, async: false

  alias Beamicom.Host.VideoFrame
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

    state = %{
      owner: nil,
      output: Output,
      reader: :nes,
      width: 256,
      height: 240,
      period_ns: round(1_000_000_000 / 60.0988)
    }

    :sys.suspend(Output)

    try do
      assert {[buffer: {:output, %Membrane.Buffer{} = buffer}], ^state} =
               VideoSource.handle_info({:frame, 1}, nil, state)

      assert buffer.payload == <<84, 84, 84>>
      assert buffer.pts == 42 * round(1_000_000_000 / 60.0988)
    after
      :sys.resume(Output)
    end
  end

  test "converts DMG shade indices and passes CGB RGB24 through" do
    shades = :binary.copy(<<0, 1, 2, 3>>, div(160 * 144, 4))

    dmg = %VideoFrame{
      system: :gbc,
      number: 0,
      width: 160,
      height: 144,
      pixel_format: {:native, :dmg_shade_index},
      data: shades
    }

    assert binary_part(VideoSource.rgb_payload(dmg), 0, 12) ==
             <<0xE0, 0xF8, 0xD0, 0x88, 0xC0, 0x70, 0x34, 0x68, 0x56, 0x08, 0x18, 0x20>>

    rgb = :binary.copy(<<12, 34, 56>>, 160 * 144)

    cgb = %VideoFrame{
      system: :gbc,
      number: 0,
      width: 160,
      height: 144,
      pixel_format: :rgb24,
      data: rgb
    }

    assert VideoSource.rgb_payload(cgb) == rgb
  end
end
