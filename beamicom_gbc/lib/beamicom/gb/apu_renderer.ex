defmodule Beamicom.GB.APURenderer do
  @moduledoc """
  Boundary for deferred Game Boy audio rendering.

  Level renderers receive channel samples computed by the live APU. Event-driven
  renderers export `event_driven?/0` and receive control-state epochs plus
  elapsed hardware dots so oscillator, wave, noise, routing, and PCM work can
  move behind the optional implementation boundary.
  """

  @type entry :: binary()

  @callback prepare(struct()) :: term()
  @callback render(term(), [entry()], non_neg_integer()) :: {binary(), term()}

  @callback render_events(term(), [[integer()]], non_neg_integer(), non_neg_integer()) ::
              {non_neg_integer(), binary(), term()}

  @callback event_driven?() :: boolean()
  @callback snapshot(term()) :: term()
  @callback restore(term()) :: term()

  @optional_callbacks render: 3, render_events: 4, event_driven?: 0, snapshot: 1, restore: 1
end
