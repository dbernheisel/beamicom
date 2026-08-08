defmodule BeamicomPhxWeb.ControllerChannel do
  use BeamicomPhxWeb, :channel

  alias Beamicom.EI.Client

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
  def join("controller:" <> port, _payload, socket) when port in ["1", "2"] do
    if Application.get_env(:beamicom_phx, :mode, :server) == :server do
      case Client.start_link(path: Beamicom.EI.default_path(), name: "beamicom-phx-channel") do
        {:ok, client} ->
          case Client.await_ready(client) do
            :ok ->
              {:ok, assign(socket, client: client, controller: String.to_integer(port))}

            {:error, reason} ->
              GenServer.stop(client)
              {:error, %{reason: inspect(reason)}}
          end

        {:error, reason} ->
          {:error, %{reason: inspect(reason)}}
      end
    else
      {:error, %{reason: "controller channels are only available in server mode"}}
    end
  end

  def join("controller:" <> _port, _payload, _socket),
    do: {:error, %{reason: "controller must be 1 or 2"}}

  @impl true
  def handle_in("buttons", %{"buttons" => names}, socket) when is_list(names) do
    with {:ok, buttons} <- decode_buttons(names),
         :ok <- Client.set_buttons(socket.assigns.client, socket.assigns.controller, buttons) do
      {:reply, :ok, socket}
    else
      _error -> {:reply, {:error, %{reason: "invalid buttons"}}, socket}
    end
  end

  def handle_in("buttons", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid buttons"}}, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{client: client} when is_pid(client) ->
        if Process.alive?(client), do: GenServer.stop(client)

      _ ->
        :ok
    end

    :ok
  end

  defp decode_buttons(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, buttons} ->
      case @buttons do
        %{^name => button} -> {:cont, {:ok, [button | buttons]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
