defmodule NxNes.Machine.Audio do
  @moduledoc "Resident audio synchronization matching the native bus's lazy clock boundary."
  import Nx.Defn

  defn tick(s, cycles) do
    audio = audio_state(s)
    audio = %{audio | apu_pending: audio.apu_pending + cycles}

    audio =
      if audio.apu_pending >= 100 and audio.apu.irq_inhibit == 0,
        do: sync_state(audio),
        else: audio

    merge_audio(s, audio)
  end

  defn sync(s) do
    merge_audio(s, sync_state(audio_state(s)))
  end

  # Keep machine RAM, PPU, mapper and CPU fields out of the audio conditional.
  # XLA otherwise has to make every field a conditional result and inserts
  # ownership copies even though the branch cannot modify those buffers.
  defnp sync_state(s) do
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

  deftransformp audio_state(s) do
    Map.take(s, [:apu, :apu_pending, :audio, :audio_count, :reason])
  end

  deftransformp merge_audio(s, audio) do
    Map.merge(s, audio)
  end
end
