defmodule Beamicom.GB.APURenderer do
  @moduledoc """
  Boundary for deferred Game Boy stereo sample mixing.

  Channel timers, the frame sequencer, register behavior, and generated channel
  levels remain in the live APU. A renderer batches routing, master-volume, and
  signed PCM conversion at the frame output boundary.
  """

  @type entry :: binary()

  @callback prepare(:dmg | :cgb) :: term()
  @callback render(term(), [entry()], non_neg_integer()) :: {binary(), term()}
end
