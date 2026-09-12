# A long, warmed Nx-only workload for external native stack sampling.
alias NxNes.{APU, Batch}
data = File.read!("tmp/devices.etf") |> :erlang.binary_to_term()
{seed, _} = Enum.find(data.apu, fn {s, _} -> s.m5_active and s.pulse1.length > 0 end)
s = APU.pack(%{seed | samples: []}) |> Batch.resident()
cycles = Nx.tensor(29830, type: :s32) |> Batch.resident()
fun = EXLA.compile(&APU.run/2, [Nx.to_template(s), Nx.to_template(cycles)], client: :host)

for _ <- 1..64 do
  {_, pcm, _, _} = fun.(s, cycles)
  Nx.to_binary(pcm)
end

File.write!("tmp/apu_profile.ready", System.pid())

Enum.reduce(1..100_000, s, fn _, state ->
  {state, pcm, count, left} = fun.(state, cycles)
  Nx.to_binary(pcm)
  Nx.to_number(count)
  0 = Nx.to_number(left)
  state
end)
