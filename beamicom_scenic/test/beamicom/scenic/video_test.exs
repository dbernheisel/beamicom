defmodule Beamicom.Scenic.VideoTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.VideoFrame
  alias Beamicom.Scenic.Video

  test "passes CGB RGB24 through and nearest-neighbor scales it" do
    rgb = <<1, 2, 3, 4, 5, 6>>

    frame = %VideoFrame{
      system: :gbc,
      number: 1,
      width: 2,
      height: 1,
      pixel_format: :rgb24,
      data: rgb
    }

    assert Video.rgb_payload(frame) == rgb

    assert Video.upscale(rgb, 2, 2) ==
             <<1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6, 1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6>>
  end

  test "converts a DMG shade-index frame using the display palette" do
    shades = :binary.copy(<<0, 1, 2, 3>>, div(160 * 144, 4))

    frame = %VideoFrame{
      system: :gbc,
      number: 1,
      width: 160,
      height: 144,
      pixel_format: {:native, :dmg_shade_index},
      data: shades
    }

    rgb = Video.rgb_payload(frame)
    assert byte_size(rgb) == 160 * 144 * 3

    assert binary_part(rgb, 0, 12) ==
             <<0xE0, 0xF8, 0xD0, 0x88, 0xC0, 0x70, 0x34, 0x68, 0x56, 8, 24, 32>>
  end
end
