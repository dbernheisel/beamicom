defmodule Beamicom.NES.APU.Triangle do
  @moduledoc "State for the 2A03 triangle channel (see `Beamicom.NES.APU`)."

  defstruct period: 0,
            length: 0,
            halt: false,
            control: false,
            linear: 0,
            linear_reload: 0,
            reload_flag: false,
            enabled: false
end
