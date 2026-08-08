defmodule BeamicomPhxWeb.ControllerSocket do
  use Phoenix.Socket

  channel "controller:*", BeamicomPhxWeb.ControllerChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
