defmodule Beamicom.SNES.DSP.Echo.Effect do
  @moduledoc """
  One phase-tagged S-DSP echo RAM access for the shared APU timeline.

  Disabled write effects remain visible so traces distinguish FLG suppression
  from an unscheduled write.
  """

  @enforce_keys [:operation, :phase, :channel, :address]
  defstruct operation: nil,
            phase: nil,
            channel: nil,
            address: nil,
            size: 2,
            value: nil,
            enabled?: true

  @type t :: %__MODULE__{}
end
