defmodule Beamicom.Scenic.LayoutTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Layout

  test "integer fitting jumps only at complete native-size stages" do
    base = {256, 240}
    source = {768, 720}

    assert %{output_size: {512, 480}, integer_scale: 2, scale: 1.0} =
             Layout.fit(base, source, {0, 0}, {767, 719}, true)

    assert %{output_size: {768, 720}, integer_scale: 3, scale: 1.0} =
             Layout.fit(base, source, {0, 0}, {768, 720}, true)

    assert %{output_size: {768, 720}, integer_scale: 3, scale: 1.0} =
             Layout.fit(base, source, {0, 0}, {1_023, 959}, true)

    assert %{output_size: {1_024, 960}, integer_scale: 4, scale: 1.0} =
             Layout.fit(base, source, {0, 0}, {1_024, 960}, true)
  end

  test "integer fitting never drops below 1x and uses pixel-aligned centering" do
    assert %{
             output_size: {256, 240},
             integer_scale: 1,
             scale: 1.0,
             position: {-28, -20}
           } = Layout.fit({256, 240}, {768, 720}, {0, 0}, {200, 200}, true)

    assert %{position: {16, 40}} =
             Layout.fit({256, 240}, {768, 720}, {0, 0}, {800, 800}, true)
  end

  test "flexible fitting retains fractional Scenic scaling when disabled" do
    assert %{output_size: {768, 720}, integer_scale: nil, scale: scale} =
             Layout.fit({256, 240}, {768, 720}, {0, 0}, {700, 600}, false)

    assert_in_delta scale, 600 / 720, 0.0001

    assert %{output_size: {768, 720}, integer_scale: nil, scale: enlarged} =
             Layout.fit({256, 240}, {768, 720}, {0, 0}, {1_200, 1_000}, false)

    assert_in_delta enlarged, 1_000 / 720, 0.0001
  end
end
