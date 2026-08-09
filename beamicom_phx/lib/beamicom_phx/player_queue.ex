defmodule BeamicomPhx.PlayerQueue do
  @moduledoc """
  Owns the single remote controller seat and its FIFO waiting queue.

  Player 1 is local to the server. The first remote controller receives Player 2;
  later controllers wait until that channel disconnects.
  """

  use GenServer

  alias Beamicom.EI.Client

  @topic "controller:lobby"
  @notification_topic "player-notifications"
  @notification_interval 4_400

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def join(pid \\ self()), do: GenServer.call(__MODULE__, {:join, pid})
  def leave(pid \\ self()), do: GenServer.call(__MODULE__, {:leave, pid})

  def subscribe do
    Phoenix.PubSub.subscribe(BeamicomPhx.PubSub, @notification_topic)
  end

  @impl true
  def init(_opts) do
    {:ok, %{player: nil, waiting: :queue.new(), monitors: %{}}}
  end

  @impl true
  def handle_call({:join, pid}, _from, %{player: nil} = state) do
    state = state |> monitor(pid) |> Map.put(:player, pid)
    broadcast("Player 2 has joined")
    {:reply, {:player, 2}, state}
  end

  def handle_call({:join, pid}, _from, state) do
    waiting = :queue.in(pid, state.waiting)
    state = state |> monitor(pid) |> Map.put(:waiting, waiting)
    {:reply, {:waiting, :queue.len(waiting)}, state}
  end

  def handle_call({:leave, pid}, _from, state) do
    {:reply, :ok, remove(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.monitors do
      %{^pid => ^ref} -> {:noreply, remove(state, pid, false)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:announce_join, pid}, %{player: pid} = state) do
    broadcast("Player 2 has joined")
    {:noreply, state}
  end

  def handle_info({:announce_join, _former_player}, state), do: {:noreply, state}

  defp monitor(state, pid) do
    put_in(state.monitors[pid], Process.monitor(pid))
  end

  defp remove(state, pid, demonitor? \\ true)

  defp remove(%{player: pid} = state, pid, demonitor?) do
    broadcast("Player 2 has left")

    state
    |> drop_monitor(pid, demonitor?)
    |> Map.put(:player, nil)
    |> clear_player_two()
    |> promote()
  end

  defp remove(state, pid, demonitor?) do
    state
    |> drop_monitor(pid, demonitor?)
    |> Map.update!(:waiting, fn waiting ->
      waiting
      |> :queue.to_list()
      |> Enum.reject(&(&1 == pid))
      |> :queue.from_list()
    end)
    |> notify_positions()
  end

  defp drop_monitor(state, pid, demonitor?) do
    {ref, monitors} = Map.pop(state.monitors, pid)

    if demonitor? and ref, do: Process.demonitor(ref, [:flush])
    %{state | monitors: monitors}
  end

  defp clear_player_two(state) do
    case Process.whereis(BeamicomPhx.EIClient) do
      nil -> :ok
      client -> Client.set_buttons(client, 2, [])
    end

    state
  end

  defp promote(state) do
    case :queue.out(state.waiting) do
      {{:value, pid}, waiting} ->
        send(pid, {:player_assigned, 2})
        Process.send_after(self(), {:announce_join, pid}, @notification_interval)

        %{state | player: pid, waiting: waiting}
        |> notify_positions()

      {:empty, _waiting} ->
        state
    end
  end

  defp notify_positions(state) do
    state.waiting
    |> :queue.to_list()
    |> Enum.with_index(1)
    |> Enum.each(fn {pid, position} -> send(pid, {:queue_position, position}) end)

    state
  end

  defp broadcast(message) do
    BeamicomPhxWeb.Endpoint.broadcast(@topic, "announcement", %{message: message})

    Phoenix.PubSub.broadcast(
      BeamicomPhx.PubSub,
      @notification_topic,
      {:player_notification, message}
    )
  end
end
