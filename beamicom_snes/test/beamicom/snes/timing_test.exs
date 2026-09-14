defmodule Beamicom.SNES.TimingTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.Timing

  test "advances across scanlines and NTSC frames" do
    timing = Timing.new() |> Timing.advance(1364 + 10)
    assert {timing.vline, timing.hclock, timing.frame} == {1, 10, 0}

    timing = Timing.new() |> Timing.advance(262 * 1364)
    assert {timing.vline, timing.hclock, timing.frame, timing.field} == {0, 0, 1, 1}
  end

  test "exposes vblank boundaries for normal and overscan rendering" do
    refute Timing.vblank?(%Timing{region: :ntsc, vline: 224})
    assert Timing.vblank?(%Timing{region: :ntsc, vline: 225})
    refute Timing.vblank?(%Timing{region: :ntsc, vline: 239, overscan?: true})
    assert Timing.vblank?(%Timing{region: :ntsc, vline: 240, overscan?: true})
    refute Timing.vblank?(%Timing{region: :ntsc, vline: 0})
  end

  test "models the documented short and long scanlines" do
    assert Timing.line_clocks(%Timing{region: :ntsc, field: 1, vline: 240}) == 1360

    assert Timing.line_clocks(%Timing{
             region: :pal,
             field: 1,
             vline: 311,
             interlace?: true
           }) == 1368
  end
end
