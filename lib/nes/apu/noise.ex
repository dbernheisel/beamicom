defmodule Beamicom.NES.APU.Noise do
  @moduledoc "State for the 2A03 noise channel (see `Beamicom.NES.APU`)."

  defstruct period: 0,
            mode: false,
            length: 0,
            halt: false,
            const: false,
            vol: 0,
            env_start: false,
            env_div: 0,
            env_decay: 0,
            enabled: false
end
