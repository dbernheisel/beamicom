defmodule Beamicom.GB.APU.Noise do
  @moduledoc false
  defstruct enabled: false,
            dac: false,
            length: 0,
            length_enable: false,
            initial_volume: 0,
            volume: 0,
            envelope_add: false,
            envelope_period: 0,
            envelope_timer: 8,
            shift: 0,
            width7: false,
            divisor: 0,
            timer: 8,
            lfsr: 0x7FFF
end
