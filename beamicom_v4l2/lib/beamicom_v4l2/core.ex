defmodule BeamicomV4L2.Core do
  @moduledoc false

  use Beamicom.Host.Registry,
    systems: [
      {Beamicom.NES.System, :nes},
      {Beamicom.GB.System, :host}
    ]
end
