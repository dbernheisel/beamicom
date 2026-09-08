defmodule Beamicom.Host.InputCapabilities do
  @moduledoc "Controller ports and controls exposed by an emulator system."

  alias Beamicom.Host.Input

  @enforce_keys [:ports]
  defstruct [:ports]

  @type t :: %__MODULE__{ports: %{required(Input.port_id()) => MapSet.t(Input.control())}}

  @doc "Build capabilities from a map of ports to enumerable control names."
  @spec new(%{required(Input.port_id()) => Enumerable.t()}) :: t()
  def new(ports) when is_map(ports) do
    %__MODULE__{ports: Map.new(ports, fn {port, controls} -> {port, MapSet.new(controls)} end)}
  end

  @doc "Whether a complete input state is supported by these capabilities."
  @spec accepts?(t(), Input.t()) :: boolean()
  def accepts?(%__MODULE__{ports: ports}, %Input{port: port, controls: controls}) do
    case Map.fetch(ports, port) do
      {:ok, supported} -> MapSet.subset?(controls, supported)
      :error -> false
    end
  end
end
