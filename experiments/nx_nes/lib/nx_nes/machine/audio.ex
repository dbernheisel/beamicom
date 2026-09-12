defmodule NxNes.Machine.Audio do
  @moduledoc "Resident audio synchronization matching the native bus's lazy clock boundary."
  import Nx.Defn

  defn tick(s, cycles) do
    s = %{s | apu_pending: s.apu_pending + cycles}
    if s.apu_pending >= 100 and s.apu.irq_inhibit == 0, do: sync(s), else: s
  end

  defn sync(s) do
    if s.apu_pending > 0 do
      {apu, pcm, count, left, _} =
        NxNes.BlockAPU.run(
          s.apu,
          Nx.tensor([[40001, 0, 0]], type: :s32),
          Nx.tensor(0, type: :s32),
          s.apu_pending
        )

      reason = Nx.select(left != 0 or s.audio_count + count > 1024, 8, s.reason)

      %{
        s
        | apu: apu,
          audio: Nx.put_slice(s.audio, [s.audio_count], pcm),
          audio_count: s.audio_count + count,
          apu_pending: left,
          reason: reason
      }
    else
      s
    end
  end
end
