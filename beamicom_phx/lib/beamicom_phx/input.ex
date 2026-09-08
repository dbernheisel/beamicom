defmodule BeamicomPhx.Input do
  @moduledoc """
  Controller input boundary. Maps browser key names to console buttons and
  forwards the currently-held set to the emulator.

  Server browsers call the local emulator directly so each LiveView remains an
  independent held-input source. A client-only node forwards through EI.
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

  @doc "Validate browser button names and return them as a button set."
  def buttons_from_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, MapSet.new()}, fn name, {:ok, buttons} ->
      case button_from_name(name) do
        nil -> {:halt, {:error, :invalid_button}}
        button -> {:cont, {:ok, MapSet.put(buttons, button)}}
      end
    end)
  end

  def buttons_from_names(_names), do: {:error, :invalid_button}

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
    case Process.whereis(BeamicomPhx.Emulator) do
      nil -> forward(port, buttons)
      _emulator -> press_local(port, buttons)
    end
  end

  @doc "Set the remote browser seat, mapped atomically to NES P2 or Game Boy P1."
  def press_remote(buttons) when is_list(buttons) do
    case Process.whereis(BeamicomPhx.Emulator) do
      nil -> forward(2, buttons)
      _emulator -> press_remote_local(buttons)
    end
  end

  defp press_local(port, buttons) do
    case BeamicomPhx.Emulator.press(port, buttons) do
      {:error, :not_loaded} -> forward(port, buttons)
      result -> result
    end
  end

  defp press_remote_local(buttons) do
    case BeamicomPhx.Emulator.press_remote(buttons) do
      {:error, :not_loaded} -> forward(2, buttons)
      result -> result
    end
  end

  defp forward(port, buttons) do
    case Process.whereis(BeamicomPhx.EIClient) do
      nil -> :ok
      client -> Beamicom.EI.Client.set_buttons(client, port, buttons)
    end
  end
end
