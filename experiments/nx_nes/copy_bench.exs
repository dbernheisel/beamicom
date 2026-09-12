alias NxNes.Machine
alias NxNes.Machine.Reference

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [checkpoint: :string, frames: :integer, output: :string]
  )

checkpoint = Keyword.get(opts, :checkpoint, "tmp/machine/checkpoint.etf")
frames = Keyword.get(opts, :frames, 5)
if frames < 1, do: raise(ArgumentError, "frames must be positive")
media = File.read!("../../beamicom/roms/castlevania3.nes")
{saved, native} = File.read!(checkpoint) |> :erlang.binary_to_term()
{:ok, initial} = Machine.load(media)
s = Map.merge(initial, saved) |> Nx.backend_copy({EXLA.Backend, client: :host})
{compile_us, run} = :timer.tc(fn -> Machine.compile(s, media, entry: 0xE047) end)
IO.puts("compile #{compile_us / 1_000_000}s")
warm_seed = Nx.backend_copy(s, {EXLA.Backend, client: :host})
{warm, _} = run.(warm_seed, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
Nx.to_number(warm.cycles)

{_, _, times} =
  Enum.reduce(1..frames, {s, native, []}, fn i, {s, native, times} ->
    {us, {s, _}} =
      :timer.tc(fn ->
        result = {next, _} = run.(s, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
        Nx.to_number(next.cycles)
        result
      end)

    {native, _, pcm} = Reference.frame(native, 0, 0)
    Reference.compare!(s, native, pcm)
    IO.puts("frame #{i}: #{us / 1000} ms exact")
    {s, native, [us | times]}
  end)

report = %{
  seed_frame: Nx.to_number(saved.ppu.frame),
  seed_cycles: Nx.to_number(saved.cycles),
  frames: frames,
  compile_ms: compile_us / 1000,
  frame_times_us: Enum.reverse(times),
  mean_ms: Enum.sum(times) / frames / 1000,
  fps: frames * 1_000_000 / Enum.sum(times),
  sequential_diagnostic: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  copy_probe: System.get_env("NX_COPY_REPORT") != nil,
  copy_probe_scope:
    "Includes one warmup plus all measured frames; timings with probe are diagnostic",
  checkpoint_sha256: Base.encode16(:crypto.hash(:sha256, File.read!(checkpoint)), case: :lower),
  validation:
    "Every measured frame matches native CPU, memory, mapper, PPU, pixels and PCM; APU floats within 1e-9"
}

if path = opts[:output], do: File.write!(path, IO.iodata_to_binary(:json.encode(report)) <> "\n")
IO.inspect(report)
