defmodule Beamicom.NES.APU.DMC do
  @moduledoc """
  DMC (delta-modulation) channel state for `Beamicom.NES.APU`.

  Kept as a sub-struct rather than flat fields on the APU so the hot per-segment
  APU map stays small — a game that never uses the DMC leaves `apu.dmc` nil and
  pays nothing. The IRQ flag lives on the APU itself (`dmc_irq`) because `irq?/1`
  is polled per CPU instruction and must stay a single top-level read.
  """

  # `rate` default is the slowest NTSC period ($4010 index 0).
  defstruct addr: 0,
            len: 0,
            rate: 428,
            loop: false,
            irq_enable: false,
            output: 0,
            timer: 0,
            bits: 0,
            shift: 0,
            sample: <<>>,
            restart: <<>>,
            fetch: false
end
