defmodule BeamicomPhxWeb.ControllerChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Beamicom.EI.Client

  @endpoint BeamicomPhxWeb.Endpoint

  test "relays complete controller state to EI" do
    :ok = BeamicomPhx.PlayerQueue.subscribe()

    {:ok, reply, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("controller-test", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    assert reply == %{player: 2, message: "Player 2 has joined"}
    assert_receive {:player_notification, "Player 2 has joined"}
    assert Client.ready?(BeamicomPhx.EIClient)

    ref = push(socket, "buttons", %{"buttons" => ["right", "a"]})
    assert_reply ref, :ok
    assert :sys.get_state(BeamicomPhx.EIClient).held[2] == MapSet.new([:right, :a])

    ref = push(socket, "buttons", %{"buttons" => []})
    assert_reply ref, :ok
    assert :sys.get_state(BeamicomPhx.EIClient).held[2] == MapSet.new()
  end

  test "rejects unknown topics and invalid buttons" do
    assert {:error, %{reason: "unknown controller channel"}} =
             BeamicomPhxWeb.ControllerSocket
             |> socket("invalid-topic", %{})
             |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:3")

    {:ok, _reply, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("invalid-buttons", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    ref = push(socket, "buttons", %{"buttons" => ["turbo"]})
    assert_reply ref, :error, %{reason: "invalid buttons"}
  end

  test "queues later clients and promotes the oldest waiter" do
    :ok = BeamicomPhx.PlayerQueue.subscribe()

    {:ok, %{player: 2}, player} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("player", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    assert_receive {:player_notification, "Player 2 has joined"}

    {:ok, waiting_reply, waiting} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("waiting", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    assert waiting_reply.player == nil
    assert waiting_reply.position == 1

    ref = push(waiting, "buttons", %{"buttons" => ["a"]})
    assert_reply ref, :error, %{reason: "waiting for Player 2"}

    Process.unlink(player.channel_pid)
    close(player)

    assert_receive {:player_notification, "Player 2 has left"}

    assert_push "player_assignment", %{
      player: 2,
      message: "You are now Player 2"
    }

    ref = push(waiting, "buttons", %{"buttons" => ["a"]})
    assert_reply ref, :ok
    assert :sys.get_state(BeamicomPhx.EIClient).held[2] == MapSet.new([:a])
  end
end
