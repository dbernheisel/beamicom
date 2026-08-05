defmodule BeamicomPhx.Input do
  @moduledoc """
  Controller input boundary. Maps browser key names to NES buttons and forwards
  the currently-held set to the emulator.

  Phase 1 (server mode): the browser connects to the node running the emulator, so
  `press/2` calls `Beamicom.NES.Runtime.set_buttons/3` locally. When no Runtime is
  running (client mode — Phase 2 — or tests) it is a no-op.

  ponytail: no node-to-node forwarding yet. When the Phase-2 client node lands,
  the `nil`-Runtime branch forwards the press to the upstream server instead.
  """

  # Browser KeyboardEvent.key -> NES button. Letters matched case-insensitively.
  @keymap %{
    "arrowup" => :up,
    "arrowdown" => :down,
    "arrowleft" => :left,
    "arrowright" => :right,
    "x" => :a,
    "z" => :b,
    "enter" => :start,
    "shift" => :select
  }

  # The NES buttons, used to validate on-screen control names from the client.
  @buttons ~w(up down left right a b start select)a
  @button_names Map.new(@buttons, fn button -> {Atom.to_string(button), button} end)

  @doc "The NES button for a browser key name, or nil if unmapped."
  def button_for(key) when is_binary(key), do: Map.get(@keymap, String.downcase(key))

  @doc "The NES button for an on-screen control name (e.g. \"a\", \"up\"), or nil if unknown."
  def button_from_name(name) when is_binary(name), do: Map.get(@button_names, name)

  @doc """
  Apply a key event to the currently-held button set. `dir` is `:down` or `:up`.
  Returns `{new_held, buttons_list}` (the list to pass to `press/2`), or `:ignore`
  for keys that aren't mapped to a button.
  """
  def apply_key(held, dir, key) when dir in [:down, :up] do
    case button_for(key) do
      nil -> :ignore
      button -> apply_button(held, dir, button)
    end
  end

  @doc """
  Apply a button press/release directly (from an on-screen control). `dir` is
  `:down`/`:up`. Returns `{new_held, buttons_list}`, or `:ignore` for an unknown
  button. Shares the held-set semantics with `apply_key/3`.
  """
  def apply_button(held, dir, button) when dir in [:down, :up] and button in @buttons do
    new_held =
      case dir do
        :down -> MapSet.put(held, button)
        :up -> MapSet.delete(held, button)
      end

    {new_held, MapSet.to_list(new_held)}
  end

  def apply_button(_held, _dir, _button), do: :ignore

  @doc """
  Set controller `port` to exactly the currently-held `buttons` (a list of button
  atoms). No-op when no local emulator Runtime is running.
  """
  def press(port, buttons) when is_integer(port) and is_list(buttons) do
    Beamicom.NES.Runtime.set_buttons(port, buttons)
  end
end
