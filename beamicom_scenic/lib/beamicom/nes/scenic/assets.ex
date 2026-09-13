defmodule Beamicom.NES.Scenic.Assets do
  @moduledoc """
  Compatibility asset-library name for `Beamicom.Scenic.Assets`.

  Existing Scenic configuration may continue to refer to this module.
  """

  defdelegate library(), to: Beamicom.Scenic.Assets
end
