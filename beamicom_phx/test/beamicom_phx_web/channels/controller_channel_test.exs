defmodule BeamicomPhxWeb.ControllerChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Beamicom.EI.Client
  alias Beamicom.NES.{Controllers, Runtime}

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

  @tag :integration
  test "routes the active remote seat to Game Boy port one" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-channel-#{System.unique_integer([:positive, :monotonic])}.gbc"
      )

    File.write!(path, Beamicom.GB.DiagnosticROM.build_cgb())

    on_exit(fn ->
      BeamicomPhx.Emulator.stop()
      File.rm(path)
    end)

    assert :ok = BeamicomPhx.Emulator.load(path)

    {:ok, %{player: 2}, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("gbc-controller", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    ref = push(socket, "buttons", %{"buttons" => ["right", "a"]})
    assert_reply ref, :ok

    %{session: %{runtime: runtime}} = :sys.get_state(BeamicomPhx.Emulator)
    assert BeamicomStream.Runtime.snapshot(runtime).bus.buttons == 0x11
    assert :sys.get_state(BeamicomPhx.EIClient).held[2] == MapSet.new()
  end

  @tag :integration
  test "preserves Player 2 routing for a running NES" do
    on_exit(&BeamicomPhx.Emulator.stop/0)
    assert :ok = BeamicomPhx.Emulator.load("test/support/fixtures/01.basics.nes")

    {:ok, %{player: 2}, socket} =
      BeamicomPhxWeb.ControllerSocket
      |> socket("nes-controller", %{})
      |> subscribe_and_join(BeamicomPhxWeb.ControllerChannel, "controller:lobby")

    ref = push(socket, "buttons", %{"buttons" => ["right", "a"]})
    assert_reply ref, :ok

    %{session: %{runtime: runtime}} = :sys.get_state(BeamicomPhx.Emulator)
    {console, _frame} = Runtime.snapshot(runtime)
    assert console.bus.pad2.buttons == Controllers.mask([:right, :a])
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
