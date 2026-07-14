defmodule Beamicom.NES.WAV do
  @moduledoc "Minimal 16-bit mono PCM WAV encoder for APU output."

  @doc "Encode signed-16-bit samples as a WAV binary at `rate` Hz (mono)."
  def encode(samples, rate \\ 44_100) do
    data = for s <- samples, into: <<>>, do: <<s::signed-little-16>>
    n = byte_size(data)

    <<"RIFF", 36 + n::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", n::little-32,
      data::binary>>
  end
end
