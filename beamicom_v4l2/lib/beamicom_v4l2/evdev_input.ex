defmodule BeamicomV4L2.EvdevInput do
  @moduledoc """
  Reads Linux keyboard events with independent press and release state.

  Terminal input only contains typed bytes, so it cannot distinguish a tap from
  a held key or track multiple held keys reliably. Linux evdev reports the
  actual key lifecycle and is therefore the preferred local controller input.
  """

  use GenServer

  alias BeamicomV4L2.Native

  @ev_key 1
  @key_release 0
  @key_press 1
  @key_repeat 2
  @keymap %{
    28 => :start,
    44 => :b,
    45 => :a,
    57 => :select,
    96 => :start,
    103 => :up,
    105 => :left,
    106 => :right,
    108 => :down
  }

  @quit_keys [1, 16]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Feed a decoded evdev event. Primarily useful for readers and tests."
  def feed(server, type, code, value), do: GenServer.cast(server, {:event, type, code, value})

  @doc "Read events from an already-open evdev device until EOF or an error."
  def read(server, keyboard), do: do_read(server, keyboard)

  @doc "Open a requested keyboard, or the first readable system keyboard."
  def with_keyboard(path \\ nil, callback) when is_function(callback, 2) do
    paths = if path, do: [Path.expand(path)], else: keyboard_paths()

    case Native.keyboard_open(paths) do
      {:ok, {keyboard, selected}} -> callback.(keyboard, selected)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       callback: Keyword.fetch!(opts, :on_buttons),
       on_quit: Keyword.get(opts, :on_quit, fn -> :ok end),
       port: Keyword.get(opts, :controller, 1),
       held: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:event, @ev_key, code, value}, state) do
    event =
      cond do
        code in @quit_keys and value == @key_press -> :quit
        button = @keymap[code] -> key_event(button, value)
        true -> nil
      end

    {:noreply, if(event, do: apply_event(event, state), else: state)}
  end

  def handle_cast({:event, _type, _code, _value}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if MapSet.size(state.held) > 0, do: notify(state, MapSet.new())
    :ok
  end

  defp apply_event(:quit, state) do
    state.on_quit.()
    state
  end

  defp apply_event({direction, button}, state) do
    held =
      case direction do
        :down -> MapSet.put(state.held, button)
        :up -> MapSet.delete(state.held, button)
      end

    if held != state.held, do: notify(state, held)
    %{state | held: held}
  end

  defp notify(state, held), do: state.callback.(state.port, MapSet.to_list(held))

  defp key_event(button, @key_press), do: {:down, button}
  defp key_event(button, @key_release), do: {:up, button}
  defp key_event(_button, @key_repeat), do: nil
  defp key_event(_button, _value), do: nil

  defp keyboard_paths do
    links =
      ["/dev/input/by-id/*-event-kbd", "/dev/input/by-path/*-event-kbd"]
      |> Enum.flat_map(&Path.wildcard/1)

    events =
      "/sys/class/input/event*"
      |> Path.wildcard()
      |> Enum.map(&Path.join("/dev/input", Path.basename(&1)))

    (links ++ events)
    |> Enum.uniq()
  end

  defp do_read(server, keyboard) do
    case Native.keyboard_read(keyboard) do
      {:ok, {type, code, value}} ->
        feed(server, type, code, value)
        do_read(server, keyboard)

      {:ok, nil} ->
        do_read(server, keyboard)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
