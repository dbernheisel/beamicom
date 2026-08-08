defmodule Beamicom.TerminalInput do
  @moduledoc """
  Portable terminal controller input for Beamicom clients.

  Terminals normally report key presses, not releases. Each recognized press is
  therefore released automatically after a short timeout; keyboard repeat
  refreshes that timeout. The parser is incremental so split ANSI arrow-key
  sequences work correctly.

  `run/2` temporarily puts `/dev/tty` into raw, no-echo mode and always restores
  its previous settings. Clients can avoid a compile-time dependency by passing
  `:on_buttons` and `:on_quit` callbacks.
  """

  use GenServer

  @buttons ~w(up down left right a b start select)a
  @arrow_sequences %{
    "\e[A" => :up,
    "\e[B" => :down,
    "\e[C" => :right,
    "\e[D" => :left
  }
  @keymap %{
    "x" => :a,
    "X" => :a,
    "z" => :b,
    "Z" => :b,
    "\r" => :start,
    "\n" => :start,
    " " => :select
  }

  @type event :: {:press, atom()} | :quit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Feed bytes into the incremental parser. Useful for adapters and tests."
  def feed(server, bytes) when is_binary(bytes), do: GenServer.cast(server, {:bytes, bytes})

  @doc "Read the controlling terminal until Q, Escape, EOF, or the quit callback fires."
  def run(server, opts \\ []) do
    with_raw_terminal(opts, fn device -> read(server, device) end)
  end

  @doc "Run a callback with the controlling terminal open in raw, no-echo mode."
  def with_raw_terminal(opts \\ [], callback) when is_function(callback, 1) do
    tty = Keyword.get(opts, :tty, "/dev/tty")

    with {:ok, previous} <- stty(tty, ["-g"]),
         {:ok, _output} <- stty(tty, ["raw", "-echo"]) do
      try do
        case File.open(tty, [:read, :binary]) do
          {:ok, device} ->
            try do
              callback.(device)
            after
              File.close(device)
            end

          {:error, reason} ->
            {:error, {:open_terminal, reason}}
        end
      after
        _ = stty(tty, [String.trim(previous)])
      end
    end
  end

  @doc "Read bytes from an already-open terminal device and feed `server`."
  def read(server, device), do: do_read_loop(server, device)

  @doc "Decode complete terminal input for tests and non-streaming adapters."
  @spec parse(binary()) :: {[event()], binary()}
  def parse(bytes), do: parse(bytes, [], "")

  @impl true
  def init(opts) do
    callback =
      Keyword.get(opts, :on_buttons, fn port, buttons ->
        Beamicom.NES.Runtime.set_buttons(
          Keyword.get(opts, :runtime, Beamicom.NES.Runtime),
          port,
          buttons
        )
      end)

    {:ok,
     %{
       callback: callback,
       on_quit: Keyword.get(opts, :on_quit, fn -> :ok end),
       port: Keyword.get(opts, :controller, 1),
       release_ms: Keyword.get(opts, :release_ms, 120),
       held: MapSet.new(),
       timers: %{},
       pending: "",
       escape_timer: nil
     }}
  end

  @impl true
  def handle_cast({:bytes, bytes}, state) do
    {events, pending} = parse(bytes, [], state.pending)
    state = cancel_escape_timer(state)
    state = Enum.reduce(events, %{state | pending: pending}, &apply_event/2)

    state =
      if pending in ["\e", "\e["] do
        %{state | escape_timer: Process.send_after(self(), :escape_timeout, 35)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:release, button, token}, state) do
    case state.timers do
      %{^button => {^token, _timer}} ->
        timers = Map.delete(state.timers, button)
        held = MapSet.delete(state.held, button)
        notify(state, held)
        {:noreply, %{state | held: held, timers: timers}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:escape_timeout, state) do
    state = %{state | pending: "", escape_timer: nil}
    state.on_quit.()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if MapSet.size(state.held) > 0, do: notify(state, MapSet.new())
    :ok
  end

  defp apply_event(:quit, state) do
    state.on_quit.()
    state
  end

  defp apply_event({:press, button}, state) when button in @buttons do
    case Map.get(state.timers, button) do
      {_token, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    token = make_ref()
    timer = Process.send_after(self(), {:release, button, token}, state.release_ms)
    held = MapSet.put(state.held, button)
    notify(state, held)
    %{state | held: held, timers: Map.put(state.timers, button, {token, timer})}
  end

  defp notify(state, held), do: state.callback.(state.port, MapSet.to_list(held))

  defp cancel_escape_timer(%{escape_timer: nil} = state), do: state

  defp cancel_escape_timer(state) do
    Process.cancel_timer(state.escape_timer)
    %{state | escape_timer: nil}
  end

  defp parse("", events, pending), do: {Enum.reverse(events), pending}

  defp parse(bytes, events, pending) when pending != "" do
    <<byte, rest::binary>> = bytes
    candidate = pending <> <<byte>>

    cond do
      button = @arrow_sequences[candidate] -> parse(rest, [{:press, button} | events], "")
      candidate == "\e[" -> parse(rest, events, candidate)
      true -> parse(rest, [:quit | events], "")
    end
  end

  defp parse(<<byte, rest::binary>>, events, "") do
    key = <<byte>>

    cond do
      key == "\e" -> parse(rest, events, key)
      key in ["q", "Q", <<3>>] -> parse(rest, [:quit | events], "")
      button = @keymap[key] -> parse(rest, [{:press, button} | events], "")
      true -> parse(rest, events, "")
    end
  end

  defp do_read_loop(server, device) do
    case IO.binread(device, 1) do
      byte when is_binary(byte) ->
        feed(server, byte)

        if byte in ["q", "Q", <<3>>] do
          :quit
        else
          do_read_loop(server, device)
        end

      :eof ->
        :eof

      {:error, reason} ->
        {:error, {:read_terminal, reason}}
    end
  end

  defp stty(tty, args) do
    case System.find_executable("stty") do
      nil -> {:error, :stty_not_found}
      executable -> run_stty(executable, tty, args)
    end
  end

  defp run_stty(executable, tty, args) do
    device_flag = if match?({:unix, :darwin}, :os.type()), do: "-f", else: "-F"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: [device_flag, tty | args]
      ])

    collect_port(port, "")
  end

  defp collect_port(port, output) do
    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data)
      {^port, {:exit_status, 0}} -> {:ok, output}
      {^port, {:exit_status, status}} -> {:error, {:stty, status, String.trim(output)}}
    after
      5_000 ->
        Port.close(port)
        {:error, :stty_timeout}
    end
  end
end
