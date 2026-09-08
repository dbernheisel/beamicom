defmodule Beamicom.Host.Input do
  @moduledoc "A complete controller state sent to an emulator core."

  @enforce_keys [:port, :controls]
  defstruct [:port, :controls]

  @type port_id :: pos_integer() | atom()
  @type control :: atom()
  @type t :: %__MODULE__{port: port_id(), controls: MapSet.t(control())}

  @doc "Build an input state and normalize its controls to a `MapSet`."
  @spec new(port_id(), Enumerable.t()) :: t()
  def new(port, controls), do: %__MODULE__{port: port, controls: MapSet.new(controls)}
end
