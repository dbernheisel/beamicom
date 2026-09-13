defmodule Beamicom.GB.DeferredFrame do
  @moduledoc false
  @enforce_keys [:model, :renderer, :lines, :state]
  defstruct [:model, :renderer, :lines, :state]
  @type t :: %__MODULE__{model: :dmg | :cgb, renderer: module(), lines: term(), state: term()}
end
