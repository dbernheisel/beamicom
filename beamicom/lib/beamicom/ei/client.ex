defmodule Beamicom.EI.Client do
  use GenServer
  alias Beamicom.EI.{Codec, Codes}

  def start_link(opts) do
    {registered_name, opts} = Keyword.pop(opts, :registered_name)

    GenServer.start_link(
      __MODULE__,
      opts,
      if(registered_name, do: [name: registered_name], else: [])
    )
  end

  def set_buttons(client, port, buttons), do: GenServer.call(client, {:set, port, buttons})
  def ready?(client), do: GenServer.call(client, :ready?)

  def await_ready(client, timeout \\ 2_000),
    do: await(client, System.monotonic_time(:millisecond) + timeout)

  def init(opts) do
    path = Path.expand(Keyword.get(opts, :path, Beamicom.EI.default_path()))

    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: 0, active: :once], 2_000) do
      {:ok, socket} ->
        {:ok,
         %{
           socket: socket,
           name: Keyword.get(opts, :name, "beamicom"),
           buffer: <<>>,
           objects: %{0 => :handshake},
           devices: %{},
           buttons: %{},
           held: %{1 => MapSet.new(), 2 => MapSet.new()},
           ready: MapSet.new(),
           last_serial: 0,
           origin: System.monotonic_time(:microsecond)
         }}

      error ->
        {:stop, error}
    end
  end

  def handle_call(:ready?, _, state), do: {:reply, MapSet.size(state.ready) == 2, state}

  def handle_call({:set, port, buttons}, _, state) when port in [1, 2] do
    valid = is_list(buttons) and Enum.all?(buttons, &(&1 in Codes.buttons()))

    if valid and MapSet.member?(state.ready, port) do
      wanted = MapSet.new(buttons)
      previous = state.held[port]
      Enum.each(MapSet.difference(wanted, previous), &send_button(state, port, &1, 1))
      Enum.each(MapSet.difference(previous, wanted), &send_button(state, port, &1, 0))

      if wanted != previous do
        elapsed = System.monotonic_time(:microsecond) - state.origin
        args = Codec.u32(state.last_serial) <> Codec.u64(elapsed)
        :gen_tcp.send(state.socket, Codec.message(state.devices[port], 3, args))
      end

      {:reply, :ok, put_in(state.held[port], wanted)}
    else
      {:reply, {:error, if(valid, do: :not_ready, else: :invalid_buttons)}, state}
    end
  end

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    {messages, buffer} = Codec.decode(state.buffer <> bytes)
    state = Enum.reduce(messages, %{state | buffer: buffer}, &dispatch/2)
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :server_closed, state}
  def handle_info({:tcp_error, _, reason}, state), do: {:stop, reason, state}
  def terminate(_, state), do: :gen_tcp.close(state.socket)

  defp dispatch({0, 0, <<version::unsigned-native-32>>}, state) do
    version = min(version, 1)

    send_many(
      state.socket,
      [
        Codec.message(0, 0, Codec.u32(version)),
        Codec.message(0, 2, Codec.u32(2)),
        Codec.message(0, 3, Codec.string(state.name))
      ] ++
        Enum.map(~w(ei_connection ei_seat ei_device ei_button), fn name ->
          Codec.message(0, 4, Codec.string(name) <> Codec.u32(1))
        end) ++ [Codec.message(0, 1)]
    )

    state
  end

  defp dispatch({0, 1, _}, state), do: state

  defp dispatch({0, 2, args}, state) do
    {serial, rest} = Codec.take_u32(args)
    {id, rest} = Codec.take_u64(rest)
    {_v, _} = Codec.take_u32(rest)
    %{state | last_serial: serial, objects: Map.put(state.objects, id, :connection)}
  end

  defp dispatch({id, 1, args}, state) do
    case state.objects[id] do
      :connection ->
        {seat, rest} = Codec.take_u64(args)
        {_v, _} = Codec.take_u32(rest)
        %{state | objects: Map.put(state.objects, seat, :seat)}

      :device ->
        state

      _ ->
        state
    end
  end

  defp dispatch({id, 2, _args}, state) do
    case state.objects[id] do
      :seat -> state
      :device -> state
      _ -> state
    end
  end

  defp dispatch({id, 3, <<>>}, state) do
    if state.objects[id] == :seat do
      :gen_tcp.send(state.socket, Codec.message(id, 1, Codec.u64(1)))
    end

    state
  end

  defp dispatch({id, 4, args}, state) do
    if state.objects[id] == :seat do
      {device, rest} = Codec.take_u64(args)
      {_v, _} = Codec.take_u32(rest)
      %{state | objects: Map.put(state.objects, device, :device)}
    else
      state
    end
  end

  defp dispatch({id, 5, args}, state) do
    if state.objects[id] == :device do
      {button, rest} = Codec.take_u64(args)
      {_name, rest} = Codec.take_string(rest)
      {_v, _} = Codec.take_u32(rest)

      %{
        state
        | objects: Map.put(state.objects, button, :button),
          buttons: Map.put(state.buttons, id, button)
      }
    else
      state
    end
  end

  defp dispatch({id, 6, <<>>}, state) when is_map_key(state.objects, id), do: state

  defp dispatch({id, 7, <<serial::unsigned-native-32>>}, state) do
    port =
      case Enum.sort(Map.keys(state.devices)) do
        [] -> 1
        [1] -> 2
        _ -> nil
      end

    if port do
      %{
        state
        | devices: Map.put(state.devices, port, id),
          ready: MapSet.put(state.ready, port),
          last_serial: serial
      }
    else
      state
    end
  end

  defp dispatch(_, state), do: state

  defp send_button(state, port, button, value) do
    {:ok, code} = Codes.code(button)
    id = state.buttons[state.devices[port]]
    :gen_tcp.send(state.socket, Codec.message(id, 1, Codec.u32(code) <> Codec.u32(value)))
  end

  defp send_many(socket, messages), do: :gen_tcp.send(socket, messages)

  defp await(client, deadline) do
    cond do
      ready?(client) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(5)
        await(client, deadline)
    end
  end
end
