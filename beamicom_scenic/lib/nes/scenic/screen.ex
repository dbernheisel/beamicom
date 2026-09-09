defmodule Beamicom.NES.Scenic.Screen do
  @moduledoc """
  Compatibility scene for `Beamicom.Scenic.Screen`.

  Existing viewport configuration may continue to use this module.
  """
  use Scenic.Scene

  defdelegate controls_height(), to: Beamicom.Scenic.Screen
  defdelegate controls_height(system), to: Beamicom.Scenic.Screen

  @impl true
  def init(scene, params, opts), do: Beamicom.Scenic.Screen.init(scene, params, opts)

  @impl true
  def handle_info(message, scene), do: Beamicom.Scenic.Screen.handle_info(message, scene)

  @impl true
  def handle_input(input, id, scene), do: Beamicom.Scenic.Screen.handle_input(input, id, scene)

  @impl true
  def handle_event(event, from, scene),
    do: Beamicom.Scenic.Screen.handle_event(event, from, scene)
end
