Code.require_file("rocm_probe.exs", __DIR__)
NxNes.Reference.load()
alias NxNes.{APU, APUReplay, BlockAPU, Batch, PPU}
data = File.read!("tmp/devices.etf") |> :erlang.binary_to_term()
resident = fn x -> Nx.backend_copy(x, {EXLA.Backend, client: :probe_rocm}) end
samples = Enum.take_every(data.ppu, 90) |> Enum.take(24)
input = samples |> Enum.map(&PPU.pack/1) |> Batch.stack() |> resident.()
chr = Nx.from_binary(data.chr, :u8) |> resident.()
f = EXLA.jit(&PPU.render/2, client: :probe_rocm)
{first_us, {pixels, status, v}} = :timer.tc(fn -> Batch.host(f.(input, chr)) end)
lines = for <<line::binary-size(256) <- Nx.to_binary(pixels)>>, do: line
actual = Enum.zip([lines, Nx.to_flat_list(status), Nx.to_flat_list(v)])

expected =
  Enum.map(samples, fn s ->
    s = struct(Beamicom.NES.PPU, Map.merge(s, %{chr: data.chr, fb: [], frame_ready: nil}))
    r = NxNes.ReferencePPU.render_scanline(s)
    {hd(r.fb), r.status, r.v}
  end)

if actual != expected, do: raise("PPU mismatch")
{warm_us, _} = :timer.tc(fn -> Batch.host(f.(input, chr)) end)
IO.inspect(%{ppu_lines: length(samples), exact: true, first_us: first_us, warm_us: warm_us})
{seed, _} = Enum.find(data.apu, fn {s, _} -> s.m5_active and s.pulse1.length > 0 end)
f = EXLA.jit(&BlockAPU.run/4, client: :probe_rocm)

entries = [
  {0, 0x5015, 3},
  {0, 0x5000, 0x9F},
  {0, 0x5002, 37},
  {0, 0x5003, 8},
  {40, 0x4000, 0x7F},
  {41, 0x4002, 19},
  {7457, 0x4015, -1},
  {7457, 0x5011, 210},
  {14913, 0x4017, 0x80},
  {14913, 0x4003, 16},
  {22371, 0x400E, 0x80},
  {29830, 0x5011, 70}
]

Enum.reduce(
  [{entries, 29830}, {[], 29830}, {[{0, 0x4015, 0}, {100, 0x5015, 0}], 1234}],
  {seed, resident.(APU.pack(seed))},
  fn {events, cycles}, {ref, nx} ->
    {ev, n} = BlockAPU.events(events, cycles)
    args = {nx, resident.(ev), resident.(n), resident.(Nx.tensor(cycles, type: :s32))}

    {us, {s, pcm, count, left, used}} =
      :timer.tc(fn ->
        {a, b, c, d} = args
        out = f.(a, b, c, d)
        Batch.host(out)
      end)

    {expected, epcm} = APUReplay.reference(ref, events, cycles)

    if Nx.to_number(left) != 0 or Nx.to_number(used) != length(events),
      do: raise("APU scheduling mismatch")

    actual = binary_part(Nx.to_binary(pcm), 0, 2 * Nx.to_number(count))
    if actual != epcm, do: raise("APU PCM mismatch")
    APUReplay.compare!(s, APU.pack(expected))

    IO.inspect(%{
      apu_cycles: cycles,
      samples: Nx.to_number(count),
      writes: length(events),
      exact_pcm: true,
      state_tolerance: 1.0e-12,
      call_with_state_export_us: us
    })

    {expected, resident.(s)}
  end
)
