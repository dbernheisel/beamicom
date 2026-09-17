defmodule Beamicom.SNES.BlarggNTSCTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [<<<: 2]

  alias Beamicom.SNES.Nx, as: SNESNx
  alias Beamicom.SNES.Nx.BlarggNTSC
  alias Beamicom.SNES.PPU

  test "composite setup table remains stable" do
    table = BlarggNTSC.Table.generate(:composite)

    assert digest(Nx.to_binary(table)) ==
             "0fac25ba8ba91c97109ab2fff36ded0b3e9abb6842352476c629d638eea391be"
  end

  test "Nx blitter produces stable RGB15-compatible output" do
    rgb =
      for y <- 0..223, x <- 0..255, into: <<>> do
        red = Bitwise.band(x * 3 + y, 31)
        green = Bitwise.band(x + y * 5, 31)
        blue = Bitwise.band(x * 7 + y * 2, 31)
        <<red <<< 3, green <<< 3, blue <<< 3>>
      end

    filtered = BlarggNTSC.filter(rgb, 0, BlarggNTSC.prepare())

    rgb15 =
      for <<red, green, blue <- filtered>>, into: <<>> do
        pixel =
          Bitwise.bor(
            Bitwise.bor(
              Bitwise.bsl(Bitwise.band(red, 0xF8), 7),
              Bitwise.bsl(Bitwise.band(green, 0xF8), 2)
            ),
            Bitwise.bsr(blue, 3)
          )

        <<pixel::native-16>>
      end

    assert byte_size(filtered) == 602 * 224 * 3

    assert digest(rgb15) ==
             "f838d9bea5154dc8cd44999f9f3774c5912ed24840c726659156004b97fae992"
  end

  test "runtime options publish widened square-pixel presentation geometry" do
    options = SNESNx.video_options(:svideo, merge_fields: false)

    assert [video_filter: {BlarggNTSC, filter_options}] = options
    assert filter_options[:preset] == :svideo
    assert filter_options[:merge_fields] == false

    assert PPU.video_capabilities(options) == %{
             width: 602,
             height: 224,
             pixel_scale: {1, 2},
             pixel_formats: [:rgb24],
             frame_rate: 60.0988
           }
  end

  test "PPU applies the Nx filter at the presentation boundary" do
    ppu = PPU.new(SNESNx.video_options(:composite))
    frame = PPU.render_frame(ppu)

    assert frame.width == 602
    assert frame.height == 224
    assert byte_size(frame.data) == 602 * 224 * 3
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
