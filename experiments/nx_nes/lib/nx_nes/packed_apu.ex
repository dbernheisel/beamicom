defmodule NxNes.PackedAPU do
  @moduledoc "Same APU equations with two resident state buffers instead of many scalar buffers."
  import Nx.Defn
  @ratio 44_100 / 1_789_773
  @paths (fn ->
            flatten = fn recurse, map, path ->
              map = if is_struct(map), do: Map.from_struct(map), else: map

              map
              |> Enum.sort()
              |> Enum.flat_map(fn {k, v} ->
                if is_map(v),
                  do: recurse.(recurse, v, path ++ [k]),
                  else: [{path ++ [k], is_float(v)}]
              end)
            end

            s =
              Beamicom.NES.APU.new()
              |> Map.from_struct()
              |> Map.drop([:samples, :dmc, :sunsoft5b])

            flatten.(flatten, s, [])
          end).()
  @ints for {p, false} <- @paths, do: p
  @floats for {p, true} <- @paths, do: p

  deftransform pack(s) do
    {Nx.stack(Enum.map(@ints, &get_in(s, &1))), Nx.stack(Enum.map(@floats, &get_in(s, &1)))}
  end

  deftransform unpack({ints, floats}) do
    Enum.reduce([{@ints, ints}, {@floats, floats}], %{}, fn {paths, tensor}, acc ->
      Enum.with_index(paths)
      |> Enum.reduce(acc, fn {path, i}, acc ->
        put_in(acc, Enum.map(path, &Access.key(&1, %{})), tensor[i])
      end)
    end)
  end

  defn run(packed, cycles) do
    {packed, left, buffer, count} =
      while {packed, left = cycles, buffer = Nx.broadcast(Nx.tensor(0, type: :s16), {1024}),
             count = Nx.tensor(0, type: :s32)},
            left > 0 and count < 1024 do
        s = unpack(packed)

        to_sample =
          Nx.max(
            1,
            Nx.as_type(Nx.ceil((1.0 - s.sample_acc) / Nx.tensor(@ratio, type: :f64)), :s32)
          )

        last = Nx.select(s.frame_mode == 5, 37281, 29829)

        target =
          Nx.select(
            s.seq_cycle < 7457,
            7457,
            Nx.select(
              s.seq_cycle < 14913,
              14913,
              Nx.select(s.seq_cycle < 22371, 22371, Nx.select(s.seq_cycle < last, last, last + 1))
            )
          )

        dc = Nx.min(left, Nx.min(to_sample, target - s.seq_cycle))
        dc = Nx.select(s.m5_active != 0, Nx.min(dc, 7457 - s.m5seq), dc)
        {s, pcm, emitted} = NxNes.APU.advance(s, dc)
        buffer = Nx.put_slice(buffer, [count], Nx.reshape(pcm, {1}))
        {pack(s), left - dc, buffer, count + emitted}
      end

    {packed, buffer, count, left}
  end
end
