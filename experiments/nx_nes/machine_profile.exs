# Warm a resident live-game checkpoint, then run continuously for native-stack sampling.
# The checkpoint comes from machine_bench.exs and is never replayed as an event trace.
media = File.read!("../../beamicom/roms/castlevania3.nes")
checkpoint = List.first(System.argv()) || "tmp/machine/checkpoint.etf"
{saved, _native_reference} = checkpoint |> File.read!() |> :erlang.binary_to_term()
{:ok, initial} = NxNes.Machine.load(media)
state = Map.merge(initial, saved) |> Nx.backend_copy({EXLA.Backend, client: :host})
compile_opts = if System.get_env("NX_PROFILE_BLOCK"), do: [entry: 0xE047], else: []
run = NxNes.Machine.compile(state, media, compile_opts)
{warm, _} = run.(state, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
Nx.to_number(warm.cycles)
File.write!(System.get_env("NX_PROFILE_READY") || "tmp/machine_profile.ready", "ready")

loop = fn recur, state ->
  {state, _} = run.(state, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
  if NxNes.Machine.status(state) != :running, do: raise("machine stopped during profiling")
  recur.(recur, state)
end

loop.(loop, warm)
