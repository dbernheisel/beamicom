defmodule Beamicom.NES.APURenderer do
  @moduledoc """
  Boundary between CPU-visible APU control and deferred waveform rendering.

  A renderer receives the previous frame's private state, timestamped APU
  operations, elapsed CPU cycles, and the native DMC DAC level at every output
  sample. Implementations may use ordinary Elixir or an optional tensor backend.
  """

  @type event :: {non_neg_integer(), non_neg_integer(), integer()}

  @callback prepare(struct()) :: term()
  @callback render(term(), [event()], non_neg_integer(), [0..127]) ::
              {non_neg_integer(), binary(), term()}
  @callback supports_event?(non_neg_integer(), integer()) :: boolean()
  @callback snapshot(term()) :: term()
  @callback restore(term()) :: term()
end
