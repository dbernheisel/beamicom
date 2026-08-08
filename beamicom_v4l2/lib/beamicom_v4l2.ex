defmodule BeamicomV4L2 do
  @moduledoc """
  Runs a Beamicom ROM on the Linux framebuffer and publishes that display as a
  V4L2 virtual camera.

  The supervised player owns the emulator runtime, framebuffer renderer, native
  V4L2 stream, and controller state. Use `BeamicomV4L2.Stream` directly only
  when another application already renders into the framebuffer.
  """

  alias BeamicomV4L2.Player

  @type option ::
          {:rom, Path.t()}
          | {:framebuffer, Path.t()}
          | {:output, Path.t()}
          | {:fps, pos_integer()}
          | {:scale, 1..8}
          | {:controls, map()}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  defdelegate start_link(options), to: Player

  @doc "Start a player for `rom`; suitable for IEx and scripts."
  @spec play(Path.t(), keyword()) :: GenServer.on_start()
  def play(rom, options \\ []), do: start_link(Keyword.put(options, :rom, rom))

  @spec status(GenServer.server()) :: map()
  defdelegate status(player \\ Player), to: Player

  @spec stop(GenServer.server()) :: :ok
  def stop(player \\ Player), do: GenServer.stop(player)

  @spec key_down(term(), 1 | 2) :: :ok | :ignore
  def key_down(key, port \\ 1), do: Player.key_event(Player, key, :down, port)

  @spec key_up(term(), 1 | 2) :: :ok | :ignore
  def key_up(key, port \\ 1), do: Player.key_event(Player, key, :up, port)

  @spec press(atom(), 1 | 2) :: :ok | :ignore
  def press(button, port \\ 1), do: Player.button_event(Player, button, :down, port)

  @spec release(atom(), 1 | 2) :: :ok | :ignore
  def release(button, port \\ 1), do: Player.button_event(Player, button, :up, port)

  @spec set_buttons([atom()], 1 | 2) :: :ok | {:error, :invalid_buttons}
  def set_buttons(buttons, port \\ 1), do: Player.set_buttons(Player, port, buttons)

  @doc false
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent
    }
  end
end
