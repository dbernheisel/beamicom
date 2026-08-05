defmodule Beamicom.NES.APU.Pulse do
  @moduledoc "State for one 2A03/MMC5 pulse channel (see `Beamicom.NES.APU`)."

  defstruct duty: 0,
            period: 0,
            length: 0,
            halt: false,
            const: false,
            vol: 0,
            env_start: false,
            env_div: 0,
            env_decay: 0,
            sweep_en: false,
            sweep_period: 0,
            sweep_neg: false,
            sweep_shift: 0,
            sweep_div: 0,
            sweep_reload: false,
            ones: false,
            enabled: false
end
