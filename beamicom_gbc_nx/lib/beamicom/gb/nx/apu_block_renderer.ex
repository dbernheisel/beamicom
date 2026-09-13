defmodule Beamicom.GB.Nx.APUBlockRenderer do
  @moduledoc """
  Frame-block EXLA mixer for DMG/CGB stereo routing and master volume.

  The native APU retains oscillator, sequencer, length, envelope, sweep, wave
  RAM, and LFSR state. It emits compact channel-level rows which this module
  converts to interleaved signed-16 PCM in one tensor operation.
  """

  import Nx.Defn
  @behaviour Beamicom.GB.APURenderer

  @capacity 1024

  @impl true
  def prepare(model) when model in [:dmg, :cgb], do: nil

  @impl true
  def render(state, entries, count) do
    rows = IO.iodata_to_binary(entries)

    unless byte_size(rows) == count * 12,
      do: raise("Game Boy APU block sample count mismatch")

    bytes =
      rows
      |> chunk_rows([])
      |> :lists.reverse()
      |> Enum.map(fn {chunk, size} ->
        padded = chunk <> :binary.copy(<<0::size(6 * 16)>>, @capacity - size)
        input = padded |> Nx.from_binary(:s16) |> Nx.reshape({@capacity, 6})
        args = [input]
        pcm = compiled(args) |> apply(args)
        pcm |> Nx.to_binary() |> binary_part(0, size * 4)
      end)
      |> IO.iodata_to_binary()

    {bytes, state}
  end

  defn mix(rows) do
    p1 = rows[[.., 0]]
    p2 = rows[[.., 1]]
    wave = rows[[.., 2]]
    noise = rows[[.., 3]]
    nr50 = rows[[.., 4]]
    nr51 = rows[[.., 5]]

    right =
      Nx.select(band(nr51, 1) != 0, p1, 0) +
        Nx.select(band(nr51, 2) != 0, p2, 0) +
        Nx.select(band(nr51, 4) != 0, wave, 0) +
        Nx.select(band(nr51, 8) != 0, noise, 0)

    left =
      Nx.select(band(nr51, 0x10) != 0, p1, 0) +
        Nx.select(band(nr51, 0x20) != 0, p2, 0) +
        Nx.select(band(nr51, 0x40) != 0, wave, 0) +
        Nx.select(band(nr51, 0x80) != 0, noise, 0)

    right = right * (band(nr50, 7) + 1) * 64
    left = left * (band(shr(nr50, 4), 7) + 1) * 64

    Nx.stack([left, right], axis: 1)
    |> Nx.clip(-32_768, 32_767)
    |> Nx.as_type(:s16)
  end

  defp chunk_rows(<<>>, chunks), do: chunks

  defp chunk_rows(binary, chunks) do
    size = min(div(byte_size(binary), 12), @capacity)
    bytes = size * 12
    <<chunk::binary-size(^bytes), rest::binary>> = binary
    chunk_rows(rest, [{chunk, size} | chunks])
  end

  defp compiled(args) do
    key = {__MODULE__, :compiled}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = EXLA.compile(&mix/1, Enum.map(args, &Nx.to_template/1), client: :host)
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
