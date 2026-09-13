defmodule Beamicom.GB.APU.Wave do
  @moduledoc false
  defstruct enabled: false,
            dac: false,
            length: 0,
            length_enable: false,
            level: 0,
            frequency: 0,
            timer: 2,
            position: 0,
            sample_buffer: 0
end
