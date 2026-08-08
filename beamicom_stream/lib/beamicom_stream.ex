defmodule BeamicomStream do
  @moduledoc "Headless AV1/Opus RTP client for the Beamicom NES emulator."

  alias BeamicomStream.Player

  def play(rom, opts \\ []), do: Player.start_link(Keyword.put(opts, :rom, rom))
  def stop(player), do: GenServer.stop(player)
  def press(player, button, port \\ 1), do: Player.button_event(player, button, :down, port)
  def release(player, button, port \\ 1), do: Player.button_event(player, button, :up, port)
  def set_buttons(player, buttons, port \\ 1), do: Player.set_buttons(player, port, buttons)
end
