defmodule Beamicom.Scenic.Component.StatusBarTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Component.StatusBar
  alias Scenic.Graph

  test "long labels remain inside the status bar" do
    width = 420

    graph =
      StatusBar.build_graph(width, %{
        fps: 59.94,
        rom: String.duplicate("long-game-name-", 20) <> ".gba",
        message: String.duplicate("configuration save failed ", 20)
      })

    assert {left, top, right, bottom} = Graph.bounds(graph)
    assert left >= 0
    assert top >= 0
    assert right <= width
    assert bottom <= StatusBar.height()

    for id <- [:rom, :right] do
      [text] = Graph.get(graph, id)
      assert String.ends_with?(text.data, "…")
    end
  end
end
