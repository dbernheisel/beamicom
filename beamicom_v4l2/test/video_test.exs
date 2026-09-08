defmodule BeamicomV4L2.VideoTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.VideoFrame
  alias BeamicomV4L2.Video

  test "converts DMG shades and passes CGB RGB24 through" do
    shades = :binary.copy(<<0, 1, 2, 3>>, div(160 * 144, 4))

    dmg = %VideoFrame{
      system: :gbc,
      number: 0,
      width: 160,
      height: 144,
      pixel_format: {:native, :dmg_shade_index},
      data: shades
    }

    assert binary_part(Video.rgb_payload(dmg), 0, 12) ==
             <<0xE0, 0xF8, 0xD0, 0x88, 0xC0, 0x70, 0x34, 0x68, 0x56, 0x08, 0x18, 0x20>>

    rgb = :binary.copy(<<12, 34, 56>>, 160 * 144)
    cgb = %{dmg | pixel_format: :rgb24, data: rgb}
    assert Video.rgb_payload(cgb) == rgb
  end
end
