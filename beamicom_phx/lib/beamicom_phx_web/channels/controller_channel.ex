defmodule BeamicomPhxWeb.ControllerChannel do
  use BeamicomPhxWeb, :channel

  @buttons %{
    "up" => :up,
    "down" => :down,
    "left" => :left,
    "right" => :right,
    "a" => :a,
    "b" => :b,
    "start" => :start,
    "select" => :select
  }

  @impl true
  def join("controller:lobby", _payload, socket) do
    if Application.get_env(:beamicom_phx, :mode, :server) == :server do
      case BeamicomPhx.PlayerQueue.join() do
        {:player, player} ->
          {:ok, %{player: player, message: "Player #{player} has joined"},
           assign(socket, controller: player)}

        {:waiting, position} ->
          {:ok, %{player: nil, position: position, message: waiting_message(position)},
           assign(socket, controller: nil)}
      end
    else
      {:error, %{reason: "controller channels are only available in server mode"}}
    end
  end

  def join("controller:" <> _topic, _payload, _socket),
    do: {:error, %{reason: "unknown controller channel"}}

  @impl true
  def handle_in("buttons", %{"buttons" => names}, socket) when is_list(names) do
    with {:ok, buttons} <- decode_buttons(names),
         2 <- socket.assigns.controller,
         :ok <- BeamicomPhx.Input.press(2, buttons) do
      {:reply, :ok, socket}
    else
      nil -> {:reply, {:error, %{reason: "waiting for Player 2"}}, socket}
      _error -> {:reply, {:error, %{reason: "invalid buttons"}}, socket}
    end
  end

  def handle_in("buttons", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid buttons"}}, socket}

  @impl true
  def handle_info({:player_assigned, 2}, socket) do
    socket = assign(socket, controller: 2)
    push(socket, "player_assignment", %{player: 2, message: "You are now Player 2"})
    {:noreply, socket}
  end

  def handle_info({:queue_position, position}, socket) do
    push(socket, "queue_position", %{position: position, message: waiting_message(position)})
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    if Process.whereis(BeamicomPhx.PlayerQueue) do
      BeamicomPhx.PlayerQueue.leave(self())
    end

    :ok
  end

  defp waiting_message(position), do: "Player 2 is occupied — you are ##{position} in line"

  defp decode_buttons(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, buttons} ->
      case @buttons do
        %{^name => button} -> {:cont, {:ok, [button | buttons]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
