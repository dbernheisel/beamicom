defmodule BeamicomV4L2.EvdevInputTest do
  use ExUnit.Case, async: true

  alias BeamicomV4L2.EvdevInput
  alias BeamicomV4L2.Native

  @tag :tmp_dir
  test "the bundled NIF opens and decodes a Linux input_event", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "keyboard-event")
    timestamp = :binary.copy(<<0>>, :erlang.system_info(:wordsize) * 2)

    File.write!(
      path,
      timestamp <> <<1::unsigned-native-16, 106::unsigned-native-16, 1::signed-native-32>>
    )

    assert {:ok, {keyboard, ^path}} = Native.keyboard_open([path])
    assert {:ok, {1, 106, 1}} = Native.keyboard_read(keyboard)
  end

  test "tracks simultaneous buttons and releases them independently" do
    owner = self()

    input =
      start_supervised!(
        {EvdevInput, on_buttons: fn port, buttons -> send(owner, {port, buttons}) end}
      )

    EvdevInput.feed(input, 1, 106, 1)
    EvdevInput.feed(input, 1, 45, 1)
    EvdevInput.feed(input, 1, 45, 0)

    assert_receive {1, [:right]}
    assert_receive {1, buttons}
    assert MapSet.new(buttons) == MapSet.new([:right, :a])
    assert_receive {1, [:right]}
    refute_receive {1, []}
  end

  test "ignores key repeat" do
    owner = self()
    input = start_supervised!({EvdevInput, on_buttons: &send(owner, {&1, &2})})
    EvdevInput.feed(input, 1, 44, 1)
    EvdevInput.feed(input, 1, 44, 2)
    EvdevInput.feed(input, 1, 44, 0)

    assert_receive {1, [:b]}
    assert_receive {1, []}
    refute_receive _message
  end

  test "Q and Escape quit on their press events" do
    owner = self()

    input =
      start_supervised!(
        {EvdevInput,
         on_buttons: fn _port, _buttons -> :ok end, on_quit: fn -> send(owner, :quit) end}
      )

    EvdevInput.feed(input, 1, 16, 1)
    EvdevInput.feed(input, 1, 1, 1)
    assert_receive :quit
    assert_receive :quit
  end
end
