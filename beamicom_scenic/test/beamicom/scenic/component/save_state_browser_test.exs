defmodule Beamicom.Scenic.Component.SaveStateBrowserTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Component.SaveStateBrowser

  test "selection is bounded and scroll offset follows the selected card" do
    assert SaveStateBrowser.next_index(0, nil, 1) == nil
    assert SaveStateBrowser.next_index(4, nil, 1) == 0
    assert SaveStateBrowser.next_index(4, 0, -1) == 0
    assert SaveStateBrowser.next_index(4, 0, 1) == 1
    assert SaveStateBrowser.next_index(4, 3, 1) == 3

    assert SaveStateBrowser.scroll_offset(700, 4, 0) == 0
    assert SaveStateBrowser.scroll_offset(700, 4, 3) > 0
    assert SaveStateBrowser.scroll_offset(700, 1, 0) == 0
  end

  test "preview layout preserves aspect ratio inside the card" do
    assert %{scale: scale, position: {x, top}, display_size: {width, display_height}} =
             SaveStateBrowser.preview_layout(256, 240)

    assert_in_delta scale, 166 / 240, 0.0001
    assert_in_delta width, 256 * scale, 0.0001
    assert_in_delta top, 0.0, 0.0001
    assert_in_delta display_height, 166.0, 0.0001
    assert x > 0

    assert %{position: {left, y}, display_size: {display_width, height}} =
             SaveStateBrowser.preview_layout(240, 160)

    assert_in_delta left, 0.0, 0.0001
    assert_in_delta display_width, 196.0, 0.0001
    assert y > 0
    assert height < 166
  end
end
