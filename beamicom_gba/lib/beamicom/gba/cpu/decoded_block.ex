defmodule Beamicom.GBA.CPU.DecodedBlock do
  @moduledoc false

  @enforce_keys [:mode, :start_address, :instructions]
  defstruct @enforce_keys ++ [source: :rom, signature: nil, accelerator: nil]
end
