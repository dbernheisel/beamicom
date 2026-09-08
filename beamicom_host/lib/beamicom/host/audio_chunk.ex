defmodule Beamicom.Host.AudioChunk do
  @moduledoc """
  A system-neutral chunk of interleaved PCM audio.

  `frame_count` is the number of sample frames, independent of channel count.
  For mono audio it is therefore the same value traditionally called the
  sample count.
  """

  @enforce_keys [:system, :sample_rate, :channels, :sample_format, :frame_count, :data]
  defstruct [:system, :sample_rate, :channels, :sample_format, :frame_count, :data]

  @type sample_format :: :s8 | :u8 | :s16le | :s16be | :s24le | :s24be | :s32le | :s32be | atom()

  @type t :: %__MODULE__{
          system: atom(),
          sample_rate: pos_integer(),
          channels: pos_integer(),
          sample_format: sample_format(),
          frame_count: non_neg_integer(),
          data: binary()
        }
end
