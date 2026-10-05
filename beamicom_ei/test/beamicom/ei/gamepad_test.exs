defmodule Beamicom.EI.GamepadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.EI.Gamepad
  alias Beamicom.EI.Server

  test "assigns controllers by connection order and promotes a waiting controller" do
    owner = self()

    gamepads =
      start_supervised!(
        {Gamepad,
         command: false,
         ports: [1, 2],
         on_buttons: fn port, buttons -> send(owner, {:buttons, port, buttons}) end}
      )

    Gamepad.feed(gamepads, connected(10, "First pad"))
    Gamepad.feed(gamepads, state(10, [:left, :a]))
    assert_receive {:buttons, 1, first_buttons}
    assert MapSet.new(first_buttons) == MapSet.new([:left, :a])

    Gamepad.feed(gamepads, connected(20, "Second pad"))
    Gamepad.feed(gamepads, state(20, [:b]))
    assert_receive {:buttons, 2, [:b]}

    Gamepad.feed(gamepads, connected(30, "Waiting pad"))
    Gamepad.feed(gamepads, state(30, [:start]))
    refute_receive {:buttons, _, [:start]}

    assert [
             %{id: 10, name: "First pad", port: 1},
             %{id: 20, name: "Second pad", port: 2},
             %{id: 30, name: "Waiting pad", port: nil}
           ] = Enum.map(Gamepad.controllers(gamepads), &Map.drop(&1, [:buttons]))

    Gamepad.feed(gamepads, disconnected(10))
    assert_receive {:buttons, 1, [:b]}
    assert_receive {:buttons, 2, [:start]}
  end

  test "decodes every standardized console button" do
    owner = self()

    gamepads =
      start_supervised!(
        {Gamepad,
         command: false,
         ports: [1],
         on_buttons: fn port, buttons -> send(owner, {port, buttons}) end}
      )

    buttons = ~w(up down left right a b x y l r select start)a
    Gamepad.feed(gamepads, connected(1, ""))
    Gamepad.feed(gamepads, state(1, buttons))

    assert_receive {1, decoded}
    assert MapSet.new(decoded) == MapSet.new(buttons)

    assert [%{name: "Unknown controller", buttons: decoded_set}] =
             Gamepad.controllers(gamepads)

    assert decoded_set == MapSet.new(buttons)

    Gamepad.feed(gamepads, disconnected(1))
    assert_receive {1, []}
  end

  test "ignores state for unknown controllers" do
    owner = self()

    gamepads =
      start_supervised!(
        {Gamepad,
         command: false,
         ports: [1],
         on_buttons: fn port, buttons -> send(owner, {port, buttons}) end}
      )

    Gamepad.feed(gamepads, state(404, [:a]))
    refute_receive {1, _buttons}
    assert Gamepad.controllers(gamepads) == []
  end

  test "rejects an invalid notification callback" do
    assert {:error, {{:invalid_on_buttons, :invalid}, _child}} =
             start_supervised({Gamepad, command: false, on_buttons: :invalid})
  end

  @tag :tmp_dir
  test "EI client", %{tmp_dir: tmp_dir} do
    owner = self()
    path = Path.join(tmp_dir, "s")

    start_supervised!({Server, path: path, ports: [1], on_buttons: &send(owner, {&1, &2})})

    gamepad =
      start_supervised!({Gamepad, command: false, path: path, ports: [1]})

    client = :sys.get_state(gamepad).client
    reference = Process.monitor(client)

    Gamepad.feed(gamepad, connected(1, "Test pad"))
    Gamepad.feed(gamepad, state(1, [:a]))
    assert_receive {1, [:a]}

    stop_supervised(Gamepad)
    assert_receive {1, []}
    assert_receive {:DOWN, ^reference, :process, ^client, :normal}
  end

  defp connected(id, name), do: <<1, id::unsigned-big-32, name::binary>>
  defp disconnected(id), do: <<3, id::unsigned-big-32>>

  defp state(id, buttons) do
    order = ~w(up down left right a b x y l r select start)a

    mask =
      buttons
      |> Enum.map(&(1 <<< Enum.find_index(order, fn button -> button == &1 end)))
      |> Enum.sum()

    <<2, id::unsigned-big-32, mask::unsigned-big-16>>
  end
end
