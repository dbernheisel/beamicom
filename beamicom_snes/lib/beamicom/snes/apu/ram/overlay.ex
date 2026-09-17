defmodule Beamicom.SNES.APU.RAM.Overlay do
  @moduledoc false

  @enforce_keys [:base]
  defstruct [:base, writes: %{}]
end
