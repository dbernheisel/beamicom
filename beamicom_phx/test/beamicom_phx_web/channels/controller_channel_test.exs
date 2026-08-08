defmodule BeamicomPhxWeb.ControllerChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Beamicom.EI.Client

  @endpoint BeamicomPhxWeb.Endpoint

  test "relays complete controller state to EI" do
    {:ok, _reply, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("controller-test", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:1")

    assert Client.ready?(socket.assigns.client)

    ref = push(socket, "buttons", %{"buttons" => ["right", "a"]})
    assert_reply ref, :ok
    assert :sys.get_state(socket.assigns.client).held[1] == MapSet.new([:right, :a])

    ref = push(socket, "buttons", %{"buttons" => []})
    assert_reply ref, :ok
    assert :sys.get_state(socket.assigns.client).held[1] == MapSet.new()
  end

  test "rejects invalid ports and buttons" do
    assert {:error, %{reason: "controller must be 1 or 2"}} =
             BeamicomPhxWeb.ControllerSocket
             |> socket("invalid-port", %{})
             |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:3")

    {:ok, _reply, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("invalid-buttons", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:1")

    ref = push(socket, "buttons", %{"buttons" => ["turbo"]})
    assert_reply ref, :error, %{reason: "invalid buttons"}
  end
end
