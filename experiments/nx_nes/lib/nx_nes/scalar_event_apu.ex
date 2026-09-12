defmodule NxNes.ScalarEventAPU do
  @moduledoc "Matched timestamped-input control retaining the original sample-by-sample Nx APU."
  import Nx.Defn
  @ratio 44_100 / 1_789_773
  defn run(s, events, event_count, cycles) do
    {s, pos, index, pcm, count, _, _, _} =
      while {s, pos = Nx.tensor(0, type: :s32), index = Nx.tensor(0, type: :s32),
             pcm = Nx.broadcast(Nx.tensor(0, type: :s16), {1024}),
             count = Nx.tensor(0, type: :s32), events, event_count, cycles},
            count < 1024 and (pos < cycles or (index < event_count and events[index][0] == pos)) do
        next_write = Nx.select(index < event_count, events[index][0], cycles + 1)

        if next_write == pos do
          s = NxNes.APUWrites.apply(s, events[index][1], events[index][2])
          {s, pos, index + 1, pcm, count, events, event_count, cycles}
        else
          to_sample =
            Nx.max(
              1,
              Nx.as_type(Nx.ceil((1.0 - s.sample_acc) / Nx.tensor(@ratio, type: :f64)), :s32)
            )

          dc =
            Nx.min(
              cycles - pos,
              Nx.min(next_write - pos, Nx.min(NxNes.BlockAPU.boundary(s), to_sample))
            )

          {s, sample, emitted} = NxNes.APU.advance(s, dc)
          pcm = Nx.put_slice(pcm, [count], Nx.reshape(sample, {1}))
          {s, pos + dc, index, pcm, count + emitted, events, event_count, cycles}
        end
      end

    {s, pcm, count, cycles - pos, index}
  end
end
