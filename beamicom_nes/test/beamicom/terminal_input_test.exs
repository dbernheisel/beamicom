defmodule Beamicom.TerminalInputTest do
  use ExUnit.Case, async: true

  alias Beamicom.TerminalInput

  test "parses arrows, buttons, start, select, and quit" do
    assert {events, ""} = TerminalInput.parse("\e[A\e[B\e[D\e[CxZ\r q")

    assert events == [
             {:press, :up},
             {:press, :down},
             {:press, :left},
             {:press, :right},
             {:press, :a},
             {:press, :b},
             {:press, :start},
             {:press, :select},
             :quit
           ]
  end

  test "retains a split escape sequence" do
    assert {[], "\e["} = TerminalInput.parse("\e[")
  end

  test "automatically releases buttons and repeat refreshes the timer" do
    parent = self()

    input =
      start_supervised!(
        {TerminalInput,
         on_buttons: fn port, buttons -> send(parent, {:buttons, port, buttons}) end,
         release_ms: 30}
      )

    TerminalInput.feed(input, "x")
    assert_receive {:buttons, 1, [:a]}
    TerminalInput.feed(input, "x")
    assert_receive {:buttons, 1, [:a]}
    assert_receive {:buttons, 1, []}, 100
    refute_receive {:buttons, 1, []}
  end
end
