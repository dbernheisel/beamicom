defmodule Beamicom.GB.APUBlockRenderer do
  @moduledoc """
  Dependency-free frame-block mixer for DMG/CGB channel levels.

  The live APU retains every hardware-visible oscillator and sequencer. It
  records compact channel-level rows and this renderer performs routing, master
  volume, clipping, and PCM encoding once at the output boundary.
  """

  import Bitwise
  @behaviour Beamicom.GB.APURenderer

  @impl true
  def prepare(%Beamicom.GB.APU{}), do: nil

  @impl true
  def render(state, entries, count) do
    rows = IO.iodata_to_binary(entries)

    unless byte_size(rows) == count * 12,
      do: raise("Game Boy APU block sample count mismatch")

    {mix_rows(rows, []), state}
  end

  defp mix_rows(<<>>, pcm), do: pcm |> :lists.reverse() |> IO.iodata_to_binary()

  defp mix_rows(
         <<p1::little-signed-16, p2::little-signed-16, wave::little-signed-16,
           noise::little-signed-16, nr50::little-signed-16, nr51::little-signed-16,
           rest::binary>>,
         pcm
       ) do
    right = routed(p1, p2, wave, noise, nr51 &&& 0x0F) * ((nr50 &&& 7) + 1) * 64
    left = routed(p1, p2, wave, noise, nr51 >>> 4) * ((nr50 >>> 4 &&& 7) + 1) * 64
    mix_rows(rest, [<<clamp(left)::little-signed-16, clamp(right)::little-signed-16>> | pcm])
  end

  defp routed(p1, p2, wave, noise, routes) do
    if((routes &&& 1) != 0, do: p1, else: 0) +
      if((routes &&& 2) != 0, do: p2, else: 0) +
      if((routes &&& 4) != 0, do: wave, else: 0) +
      if((routes &&& 8) != 0, do: noise, else: 0)
  end

  defp clamp(value) when value > 32_767, do: 32_767
  defp clamp(value) when value < -32_768, do: -32_768
  defp clamp(value), do: value
end
