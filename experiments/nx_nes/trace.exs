defmodule TraceWorkload do
  alias Beamicom.NES.{Console, CPU, Bus}

  def run(path) do
    c = Console.load(path)
    {counts, snapshots} = walk(c, %{}, %{}, 902)
    top = counts |> Enum.sort_by(fn {_, n} -> -n end) |> Enum.take(20)
    File.mkdir_p!("tmp")
    snapshots = Map.take(snapshots, Enum.map(top, &elem(&1, 0)))
    File.write!("tmp/hot_snapshots.etf", :erlang.term_to_binary({top, snapshots}, [:compressed]))

    IO.inspect(%{frames: 902, instructions: Enum.sum(Map.values(counts)), top: top},
      limit: :infinity
    )
  end

  defp walk(c, counts, snapshots, frames) do
    key = {c.cpu.pc, c.bus.prg_banks}
    counts = Map.update(counts, key, 1, &(&1 + 1))
    # Store just CPU and memory; never retain all historical framebuffer states.
    snapshots =
      if Map.has_key?(snapshots, key),
        do: snapshots,
        else: Map.put(snapshots, key, {c.cpu, %{c.bus | ppu: nil, apu: nil}})

    {cpu, bus} = CPU.step(c.cpu, c.bus)

    previous_number = if c.bus.ppu.frame_ready, do: c.bus.ppu.frame_ready.number, else: -1
    ready = bus.ppu.frame_ready
    new_frame = ready != nil and ready.number > previous_number

    if new_frame and frames == 1 do
      {counts, snapshots}
    else
      {_, _, bus} =
        if new_frame, do: Bus.take_audio_pcm(bus), else: {0, <<>>, bus}

      walk(%{c | cpu: cpu, bus: bus}, counts, snapshots, frames - if(new_frame, do: 1, else: 0))
    end
  end
end

TraceWorkload.run(hd(System.argv()))
