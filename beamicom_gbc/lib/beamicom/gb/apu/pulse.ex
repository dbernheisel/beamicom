defmodule Beamicom.GB.APU.Pulse do
  @moduledoc false
  defstruct enabled: false,
            dac: false,
            length: 0,
            length_enable: false,
            duty: 0,
            duty_pos: 0,
            frequency: 0,
            timer: 4,
            initial_volume: 0,
            volume: 0,
            envelope_add: false,
            envelope_period: 0,
            envelope_timer: 8,
            sweep_period: 0,
            sweep_negate: false,
            sweep_shift: 0,
            sweep_timer: 8,
            sweep_shadow: 0,
            sweep_enabled: false
end
