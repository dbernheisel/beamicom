NxNes.Reference.load()
alias NxNes.{APU, APUReplay, BlockAPU, ScalarEventAPU, Batch}
data = File.read!("tmp/apu_events.etf") |> :erlang.binary_to_term()
chunks = APUReplay.chunks(data.events, data.cycles)
seed = %{data.initial | samples: []}
initial = APU.pack(seed) |> Batch.resident()

ref_run = fn ->
  Enum.reduce(chunks, {seed, []}, fn chunk, {s, out} ->
    {s, pcm} = APUReplay.reference(s, chunk.events, chunk.cycles)
    {s, [pcm | out]}
  end)
end

{ref_final, ref_pcm} = ref_run.()
APUReplay.compare!(APU.pack(ref_final), APU.pack(data.final))
reference_audio = ref_pcm |> Enum.reverse() |> IO.iodata_to_binary()
if reference_audio != data.pcm, do: raise("timestamped replay differs from original game PCM")

IO.inspect(%{
  chunks: length(chunks),
  max_events: Enum.max(Enum.map(chunks, &length(&1.events))),
  game_pcm_exact: reference_audio == data.pcm,
  game_final_state_verified: true,
  samples: div(byte_size(reference_audio), 2)
})

runners =
  for {name, kernel} <- [
        {:scalar_events, &ScalarEventAPU.run/4},
        {:block_events, &BlockAPU.run/4}
      ] do
    {events, n, cycles} = hd(chunks).args

    {compile, fun} =
      :timer.tc(fn ->
        EXLA.compile(kernel, Enum.map([initial, events, n, cycles], &Nx.to_template/1),
          client: :host
        )
      end)

    run = fn ->
      Enum.reduce(chunks, {initial, []}, fn chunk, {s, out} ->
        {events, n, cycles} = chunk.args
        {s, pcm, count, left, used} = fun.(s, events, n, cycles)

        if Nx.to_number(left) != 0 or Nx.to_number(used) != length(chunk.events),
          do: raise("unconsumed input")

        pcm = Nx.to_binary(pcm) |> binary_part(0, 2 * Nx.to_number(count))
        {s, [pcm | out]}
      end)
    end

    {elapsed, {final, pcm}} = :timer.tc(run)

    if pcm != ref_pcm do
      mismatches =
        Enum.zip(pcm, ref_pcm) |> Enum.with_index() |> Enum.filter(fn {{a, b}, _} -> a != b end)

      raise(
        "#{name}: PCM differs in #{length(mismatches)} chunks; first reversed index #{elem(hd(mismatches), 1)}"
      )
    end

    APUReplay.compare!(final, APU.pack(ref_final))

    IO.inspect(%{
      variant: name,
      compile_ms: compile / 1000,
      first_ms: elapsed / 1000,
      correctness: :passed
    })

    {name, run, compile}
  end

all = [{:elixir, ref_run, 0} | runners]

times =
  Enum.reduce(0..4, %{}, fn round, acc ->
    {a, b} = Enum.split(all, rem(round, length(all)))

    Enum.reduce(b ++ a, acc, fn {name, fun, _}, acc ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      Map.update(acc, name, [us], &(&1 ++ [us]))
    end)
  end)

result = %{
  scope:
    "full 15-second Castlevania timed APU-operation replay, resident Nx state, per-block PCM export; CPU/PPU not running during timing",
  diagnostic_sequential: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  cycles: data.cycles,
  events: length(data.events),
  blocks: length(chunks),
  block_samples: 128,
  timings_us: times,
  compile_ms: Map.new(runners, fn {n, _, c} -> {n, c / 1000} end),
  game_pcm_exact: reference_audio == data.pcm,
  game_final_state_verified: true,
  samples: div(byte_size(reference_audio), 2),
  pcm_sha256: Base.encode16(:crypto.hash(:sha256, reference_audio), case: :lower),
  correctness:
    "Nx PCM exact against timestamped Elixir replay; final integer state exact, floating state within 1e-12"
}

File.write!(
  List.first(System.argv()) || "results/apu_blocks.json",
  IO.iodata_to_binary(:json.encode(result)) <> "\n"
)

IO.inspect(result)
