defmodule Beamicom.NES.Scenic do
  @moduledoc """
  Backwards-compatible entry point for the multi-system Scenic host.

  New code may call `Beamicom.Scenic.play/2`. Both entry points select the NES
  or Game Boy core from the supplied media.
  """

  defdelegate play(path), to: Beamicom.Scenic
  defdelegate play(path, options), to: Beamicom.Scenic
end
