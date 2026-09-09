defmodule Beamicom.Scenic.Core do
  @moduledoc false

  use Beamicom.Host.Registry,
    systems: [
      {Beamicom.NES.System, :nes},
      {Beamicom.GB.System, :host}
    ],
    extra_extensions: [{".png", Beamicom.NES.System}],
    signatures: [
      {<<"NES", 0x1A>>, Beamicom.NES.System},
      {<<137, 80, 78, 71, 13, 10, 26, 10>>, Beamicom.NES.System}
    ]
end
