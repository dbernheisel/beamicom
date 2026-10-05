defmodule Beamicom.EI.Gamepad do
  @moduledoc """
  Reads SDL's standardized game-controller state from a native Port.

  Controllers are assigned by connection order to the emulator's available
  ports. SDL normalizes USB and Bluetooth devices to the same named buttons, so
  supported Xbox, PlayStation, Nintendo, and third-party pads share this path.
  The native helper reports complete state, and the Elixir process forwards it
  through a dedicated EI client so every frontend can share the same physical
  controller adapter and union its state with other EI input sources.

  ```mermaid
  stateDiagram-v2
    [*] --> Waiting
    Waiting --> Assigned: controller connected
    Assigned --> Assigned: buttons or stick changed
    Assigned --> Waiting: controller disconnected
    Assigned --> Promoted: earlier controller disconnected
    Promoted --> Assigned: publish replacement state
  ```
  """

  use GenServer

  import Bitwise

  require Logger

  alias Beamicom.EI.Client

  @connected 1
  @state 2
  @disconnected 3
  @buttons ~w(up down left right a b x y l r select start)a

  defstruct [
    :client,
    :notify,
    :port,
    devices: %{},
    next_sequence: 0,
    ports: [],
    published: %{}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def feed(server, packet) when is_binary(packet), do: GenServer.cast(server, {:packet, packet})

  @doc "Returns connected controllers and their current player-port assignments."
  def controllers(server), do: GenServer.call(server, :controllers)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ports = Keyword.get(opts, :ports, [1, 2])

    unless ports in [[1], [1, 2]] do
      raise ArgumentError, ":ports must be [1] or [1, 2]"
    end

    with {:ok, command} <- resolve_command(opts),
         {:ok, client, notify} <- start_notifier(opts, ports) do
      {:ok,
       %__MODULE__{
         client: client,
         notify: notify,
         port: open_native(command),
         ports: ports,
         published: Map.new(ports, &{&1, MapSet.new()})
       }}
    else
      :ignore -> :ignore
      {:stop, reason} -> {:stop, reason}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:controllers, _from, state) do
    assignments = assignments(state)

    controllers =
      state.devices
      |> Enum.sort_by(fn {_id, device} -> device.sequence end)
      |> Enum.map(fn {id, device} ->
        %{id: id, name: device.name, port: Map.get(assignments, id), buttons: device.buttons}
      end)

    {:reply, controllers, state}
  end

  @impl true
  def handle_cast({:packet, packet}, state), do: {:noreply, dispatch(packet, state)}

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port} = state),
    do: {:noreply, dispatch(packet, state)}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:native_exit, status}, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when is_port(port),
    do: {:stop, {:native_exit, reason}, state}

  def handle_info({:EXIT, client, reason}, %{client: client} = state) when is_pid(client),
    do: {:stop, {:ei_client_exit, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.published, fn {port, buttons} ->
      if MapSet.size(buttons) > 0, do: state.notify.(port, [])
    end)

    close_native(state.port)
    close_client(state.client)
    :ok
  end

  defp dispatch(<<@connected, id::unsigned-big-32, name::binary>>, state) do
    if Map.has_key?(state.devices, id) do
      state
      |> put_in([Access.key(:devices), id, :name], display_name(name))
      |> publish()
    else
      device = %{
        name: display_name(name),
        buttons: MapSet.new(),
        sequence: state.next_sequence
      }

      %{
        state
        | devices: Map.put(state.devices, id, device),
          next_sequence: state.next_sequence + 1
      }
      |> publish()
    end
  end

  defp dispatch(<<@state, id::unsigned-big-32, mask::unsigned-big-16>>, state) do
    case Map.fetch(state.devices, id) do
      {:ok, device} ->
        %{state | devices: Map.put(state.devices, id, %{device | buttons: decode_buttons(mask)})}
        |> publish()

      :error ->
        state
    end
  end

  defp dispatch(<<@disconnected, id::unsigned-big-32>>, state) do
    %{state | devices: Map.delete(state.devices, id)}
    |> publish()
  end

  defp dispatch(packet, state) do
    Logger.warning("ignoring invalid native gamepad packet: #{inspect(packet)}")
    state
  end

  defp publish(state) do
    assignments = assignments(state)

    current =
      Map.new(state.ports, fn port ->
        buttons =
          Enum.find_value(assignments, MapSet.new(), fn {id, assigned_port} ->
            if assigned_port == port, do: state.devices[id].buttons
          end)

        {port, buttons}
      end)

    Enum.each(state.ports, fn port ->
      if current[port] != state.published[port] do
        state.notify.(port, current[port] |> MapSet.to_list() |> Enum.sort())
      end
    end)

    %{state | published: current}
  end

  defp assignments(state) do
    state.devices
    |> Enum.sort_by(fn {_id, device} -> device.sequence end)
    |> Enum.take(length(state.ports))
    |> Enum.map(&elem(&1, 0))
    |> Enum.zip(state.ports)
    |> Map.new()
  end

  defp decode_buttons(mask) do
    @buttons
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {button, bit}, buttons ->
      if (mask &&& 1 <<< bit) != 0, do: MapSet.put(buttons, button), else: buttons
    end)
  end

  defp display_name(""), do: "Unknown controller"
  defp display_name(name), do: name

  defp resolve_command(opts) do
    case Keyword.fetch(opts, :command) do
      {:ok, false} ->
        {:ok, nil}

      {:ok, [executable | arguments]} when is_binary(executable) and is_list(arguments) ->
        {:ok, [executable | arguments]}

      {:ok, command} ->
        {:stop, {:invalid_gamepad_command, command}}

      :error ->
        path = Application.app_dir(:beamicom_ei, "priv/native/gamepad_input")
        if File.regular?(path), do: {:ok, [path]}, else: :ignore
    end
  end

  defp start_notifier(opts, ports) do
    case Keyword.fetch(opts, :on_buttons) do
      {:ok, notify} when is_function(notify, 2) ->
        {:ok, nil, notify}

      {:ok, notify} ->
        {:error, {:invalid_on_buttons, notify}}

      :error ->
        with {:ok, client} <-
               Client.start_link(
                 name: "beamicom-gamepad",
                 path: Keyword.fetch!(opts, :path),
                 ports: ports
               ),
             :ok <- Client.await_ready(client) do
          {:ok, client, fn port, buttons -> Client.set_buttons(client, port, buttons) end}
        end
    end
  end

  defp open_native(nil), do: nil

  defp open_native([executable | arguments]) do
    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, {:packet, 2}, args: arguments]
    )
  end

  defp close_native(nil), do: :ok

  defp close_native(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp close_client(nil), do: :ok

  defp close_client(client) do
    if Process.alive?(client), do: GenServer.stop(client)
    :ok
  end
end
