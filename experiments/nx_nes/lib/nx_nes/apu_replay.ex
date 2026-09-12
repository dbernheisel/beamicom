defmodule NxNes.APUReplay do
  @compile {:no_warn_undefined, NxNes.ReferenceAPU}
  @moduledoc "Preparation and independent Elixir reference for the timestamped audio experiment."
  def reference(s, events, cycles) do
    {s, pos} =
      Enum.reduce(events, {s, 0}, fn {t, addr, v}, {s, pos} ->
        s = NxNes.ReferenceAPU.run(s, t - pos)

        s =
          cond do
            addr == 0x4015 and v == -1 -> elem(Beamicom.NES.APU.read_status(s), 1)
            addr >= 0x5000 -> Beamicom.NES.APU.mmc5_write(s, addr, v)
            true -> Beamicom.NES.APU.write(s, addr, v)
          end

        {s, t}
      end)

    s = NxNes.ReferenceAPU.run(s, cycles - pos)
    {_, pcm, s} = Beamicom.NES.APU.take_pcm(s)
    {s, pcm}
  end

  def chunks(events, cycles, width \\ 29830), do: chunks(events, cycles, width, 0, [])
  defp chunks([], cycles, _, cycles, acc), do: Enum.reverse(acc)

  defp chunks(events, cycles, width, pos, acc) do
    last = min(cycles, pos + width)
    {now, rest} = Enum.split_while(events, fn {t, _, _} -> t <= last end)
    relative = Enum.map(now, fn {t, a, v} -> {t - pos, a, v} end)
    {tensor, count} = NxNes.BlockAPU.events(relative, last - pos)

    chunk = %{
      events: relative,
      cycles: last - pos,
      args:
        {NxNes.Batch.resident(tensor), NxNes.Batch.resident(count),
         NxNes.Batch.resident(Nx.tensor(last - pos, type: :s32))}
    }

    chunks(rest, cycles, width, last, [chunk | acc])
  end

  def compare!(a, e, path \\ []) do
    Enum.each(e, fn {k, v} ->
      actual = Map.fetch!(a, k)

      if is_struct(v, Nx.Tensor) do
        x = Nx.to_number(actual)
        y = Nx.to_number(v)

        if abs(x - y) > 1.0e-12,
          do: raise("state differs at #{inspect(path ++ [k])}: #{x} != #{y}")
      else
        compare!(actual, v, path ++ [k])
      end
    end)
  end
end
