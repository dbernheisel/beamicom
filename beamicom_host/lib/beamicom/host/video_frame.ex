defmodule Beamicom.Host.VideoFrame do
  @moduledoc """
  A system-neutral video frame passed from an emulator core to a host.

  `pixel_format` describes `data`. Cores may use a host-ready format such as
  `:rgb24`, or a private format such as `{:native, :nes_framebuffer}` that an
  adapter resolves at the presentation boundary.
  """

  @enforce_keys [:system, :number, :width, :height, :pixel_format, :data]
  defstruct [:system, :number, :width, :height, :pixel_format, :data, :duration_ns, metadata: %{}]

  @type pixel_format :: atom() | {:native, atom()}

  @type t :: %__MODULE__{
          system: atom(),
          number: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          pixel_format: pixel_format(),
          data: term(),
          duration_ns: pos_integer() | nil,
          metadata: map()
        }
end
