defmodule Beamicom.EI.Server do
  use GenServer
  alias Beamicom.EI.{Codec, Codes}
  @base 0xFF00000000000000
  @seat @base + 1
  @device1 @base + 2
  @button1 @base + 3
  @device2 @base + 4
  @button2 @base + 5
  @button_cap 1
  @empty %{1 => MapSet.new(), 2 => MapSet.new()}

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def path(server), do: GenServer.call(server, :path)

  def init(opts) do
    path = Path.expand(Keyword.get(opts, :path, Beamicom.EI.default_path()))
    callback = Keyword.fetch!(opts, :on_buttons)
    File.mkdir_p!(Path.dirname(path))
    remove_stale(path)

    {:ok, listener} =
      :gen_tcp.listen(0,
        mode: :binary,
        packet: 0,
        active: false,
        ifaddr: {:local, path},
        backlog: 8
      )

    File.chmod!(path, 0o600)
    accept(listener)
    {:ok, %{path: path, listener: listener, callback: callback, clients: %{}, published: @empty}}
  end

  def handle_call(:path, _, state), do: {:reply, state.path, state}

  def handle_info({:accepted, socket}, state) do
    :inet.setopts(socket, active: :once)
    send_msg(socket, 0, 0, Codec.u32(1))

    client = %{
      buffer: <<>>,
      phase: :handshake,
      context: nil,
      interfaces: %{},
      objects: %{0 => :handshake},
      held: @empty,
      pending: @empty,
      serial: 0
    }

    accept(state.listener)
    {:noreply, put_in(state.clients[socket], client)}
  end

  def handle_info({:tcp, socket, bytes}, state) do
    client = state.clients[socket]
    {messages, buffer} = Codec.decode(client.buffer <> bytes)

    {client, valid?} =
      Enum.reduce(messages, {%{client | buffer: buffer}, true}, fn msg, {c, ok} ->
        if ok, do: dispatch(socket, msg, c), else: {c, false}
      end)

    if valid? do
      :inet.setopts(socket, active: :once)
      state = put_in(state.clients[socket], client) |> publish()
      {:noreply, state}
    else
      {:noreply, disconnect(socket, state)}
    end
  end

  def handle_info({tag, socket}, state) when tag in [:tcp_closed],
    do: {:noreply, disconnect(socket, state)}

  def handle_info({:tcp_error, socket, _}, state), do: {:noreply, disconnect(socket, state)}
  def handle_info({:accept_error, :closed}, state), do: {:noreply, state}
  def handle_info({:accept_error, reason}, state), do: {:stop, reason, state}

  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Enum.each(Map.keys(state.clients), &:gen_tcp.close/1)
    File.rm(state.path)
  end

  # handshake requests
  defp dispatch(_s, {0, 0, <<1::unsigned-native-32>>}, c), do: {c, true}
  defp dispatch(_s, {0, 2, <<2::unsigned-native-32>>}, c), do: {%{c | context: :sender}, true}
  defp dispatch(_s, {0, 3, _}, c), do: {c, true}

  defp dispatch(_s, {0, 4, args}, c) do
    {name, rest} = Codec.take_string(args)
    {version, _} = Codec.take_u32(rest)
    {%{c | interfaces: Map.put(c.interfaces, name, version)}, true}
  end

  defp dispatch(s, {0, 1, <<>>}, %{context: :sender} = c) do
    required = ~w(ei_connection ei_seat ei_device ei_button)

    if Enum.all?(required, &Map.has_key?(c.interfaces, &1)) do
      Enum.each(required, fn name -> send_msg(s, 0, 1, Codec.string(name) <> Codec.u32(1)) end)
      serial = 1
      send_msg(s, 0, 2, Codec.u32(serial) <> Codec.u64(@base) <> Codec.u32(1))
      send_msg(s, @base, 1, Codec.u64(@base + 1) <> Codec.u32(1))
      send_msg(s, @base + 1, 1, Codec.string("beamicom"))
      send_msg(s, @base + 1, 2, Codec.u64(@button_cap) <> Codec.string("ei_button"))
      send_msg(s, @base + 1, 3)
      objects = %{@base => :connection, (@base + 1) => :seat}
      {%{c | phase: :connected, serial: serial, objects: objects}, true}
    else
      {c, false}
    end
  end

  # seat bind
  defp dispatch(s, {@seat, 1, <<caps::unsigned-native-64>>}, c) do
    if Bitwise.band(caps, @button_cap) != 0 do
      c = Enum.reduce(1..2, c, fn port, acc -> advertise_device(s, acc, port) end)
      {c, true}
    else
      {c, true}
    end
  end

  # device lifecycle
  defp dispatch(_s, {id, 1, _args}, c) when id in [@device1, @device2], do: {c, true}

  defp dispatch(_s, {id, 2, _args}, c) when id in [@device1, @device2] do
    port = if id == @device1, do: 1, else: 2

    {%{
       c
       | held: Map.put(c.held, port, MapSet.new()),
         pending: Map.put(c.pending, port, MapSet.new())
     }, true}
  end

  defp dispatch(_s, {id, 3, _args}, c) when id in [@device1, @device2] do
    port = if id == @device1, do: 1, else: 2
    {%{c | held: Map.put(c.held, port, c.pending[port])}, true}
  end

  # button request
  defp dispatch(_s, {id, 1, <<code::unsigned-native-32, value::unsigned-native-32>>}, c)
       when id in [@button1, @button2] and value in [0, 1] do
    port = if id == @button1, do: 1, else: 2

    case Codes.button(code) do
      nil ->
        {c, false}

      button ->
        buttons =
          if value == 1,
            do: MapSet.put(c.pending[port], button),
            else: MapSet.delete(c.pending[port], button)

        {%{c | pending: Map.put(c.pending, port, buttons)}, true}
    end
  end

  defp dispatch(_s, _message, c), do: {c, false}

  defp advertise_device(s, c, port) do
    device = @base + if(port == 1, do: 2, else: 4)
    button = device + 1
    send_msg(s, @base + 1, 4, Codec.u64(device) <> Codec.u32(1))
    send_msg(s, device, 1, Codec.string("Beamicom Controller #{port}"))
    send_msg(s, device, 2, Codec.u32(1))
    send_msg(s, device, 5, Codec.u64(button) <> Codec.string("ei_button") <> Codec.u32(1))
    send_msg(s, device, 6)
    serial = c.serial + 1
    send_msg(s, device, 7, Codec.u32(serial))

    %{
      c
      | serial: serial,
        objects: c.objects |> Map.put(device, {:device, port}) |> Map.put(button, {:button, port})
    }
  end

  defp publish(state) do
    current =
      Map.new(1..2, fn port ->
        {port,
         Enum.reduce(state.clients, MapSet.new(), fn {_, c}, set ->
           MapSet.union(set, c.held[port])
         end)}
      end)

    Enum.each(1..2, fn port ->
      if current[port] != state.published[port],
        do: state.callback.(port, Enum.sort(MapSet.to_list(current[port])))
    end)

    %{state | published: current}
  end

  defp disconnect(socket, state) do
    :gen_tcp.close(socket)
    %{state | clients: Map.delete(state.clients, socket)} |> publish()
  end

  defp send_msg(s, id, op, args \\ <<>>), do: :gen_tcp.send(s, Codec.message(id, op, args))

  defp accept(listener) do
    owner = self()

    spawn(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          :gen_tcp.controlling_process(socket, owner)
          send(owner, {:accepted, socket})

        {:error, reason} ->
          send(owner, {:accept_error, reason})
      end
    end)
  end

  defp remove_stale(path) do
    case File.lstat(path) do
      {:ok, %{type: :other}} -> File.rm!(path)
      {:ok, _} -> raise "refusing to replace non-socket path #{path}"
      {:error, :enoent} -> :ok
    end
  end
end
