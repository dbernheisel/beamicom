alias NxNes.Core
alias NxNes.Core.{Blocks, CPU}
alias Beamicom.NES.{Cart, Bus}

# Freeze the PRG mapping from the recorded Castlevania III hot-loop snapshot.
# This preserves the real instruction bytes/PC/RAM but intentionally excludes
# MMC5 bank switching, PPU, APU and interrupts: it is a CPU-only experiment.
{_, snapshots} = File.read!("tmp/hot_snapshots.etf") |> :erlang.binary_to_term()

{{entry, _}, {native_cpu, captured_bus}} =
  Enum.find(snapshots, fn {{pc, _}, _} -> pc == 0xE047 end)

prg = for addr <- 0x8000..0xFFFF, into: <<>>, do: <<Bus.peek(captured_bus, addr)>>
media = <<"NES", 26, 2, 0, 0::80>> <> prg
{:ok, block} = Blocks.analyze(media, entry)
{:ok, initial} = Core.load(media, pc: entry)

initial =
  Enum.reduce([:a, :x, :y, :sp, :p], initial, fn key, s ->
    Map.put(s, key, Nx.tensor(Map.fetch!(native_cpu, key), type: :s32))
  end)

initial = %{
  initial
  | cycles: Nx.tensor(native_cpu.cycles, type: :s64),
    ram: Nx.from_binary(captured_bus.ram, :u8)
}

initial = Nx.backend_copy(initial, {EXLA.Backend, client: :host})
{:ok, cart} = Cart.parse(media)
native_bus = %{Bus.new(cart) | ram: captured_bus.ram}
iterations = 8192
instructions = iterations * block.count

reference = fn ->
  Enum.reduce(1..instructions, {native_cpu, native_bus}, fn _, {c, b} ->
    Beamicom.NES.CPU.step(c, b)
  end)
end

{expected, expected_bus} = reference.()
templates = [Nx.to_template(initial), Nx.template({}, :s64), Nx.template({}, :s32)]

{generic_compile, generic} =
  :timer.tc(fn -> EXLA.compile(&CPU.run/3, templates, client: :host) end)

{fused_compile, fused} =
  :timer.tc(fn ->
    EXLA.compile(fn s, d, l -> Blocks.run(s, d, l, block: block) end, templates, client: :host)
  end)

IO.inspect(%{
  block: block,
  generic_compile_ms: generic_compile / 1000,
  fused_compile_ms: fused_compile / 1000
})

variants =
  for {name, fun} <- [{"generic_nx", generic}, {"blocks_nx", fused}],
      horizon <- [113, 114, 7457, 1_000_000] do
    run = fn ->
      loop = fn rec, s, left, d, calls, hits ->
        result = fun.(s, Nx.tensor(d, type: :s64), Nx.tensor(left, type: :s32))
        s = elem(result, 0)
        n = Nx.to_number(elem(result, 1))
        hits = hits + if(tuple_size(result) == 3, do: Nx.to_number(elem(result, 2)), else: 0)

        if left == n do
          {s, calls + 1, hits}
        else
          if Core.stop(s) != :deadline, do: raise("unexpected stop #{Core.stop(s)}")
          rec.(rec, s, left - n, d + horizon, calls + 1, hits)
        end
      end

      loop.(loop, initial, instructions, native_cpu.cycles + horizon, 0, 0)
    end

    {s, calls, hits} = run.()

    if Core.cpu(s) != Map.take(Map.from_struct(expected), [:a, :x, :y, :sp, :p, :pc, :cycles]),
      do: raise("CPU mismatch")

    if Nx.to_binary(s.ram) != expected_bus.ram, do: raise("RAM mismatch")

    {"#{name}_#{horizon}", run,
     %{calls: calls, blocks: hits, fused_instructions: hits * block.count}}
  end

all = [{"native", reference, %{}} | variants]

times =
  Enum.reduce(0..4, %{}, fn round, acc ->
    {a, b} = Enum.split(all, rem(round, length(all)))

    Enum.reduce(b ++ a, acc, fn {key, f, _}, acc ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      IO.puts("#{key}: #{us / 1000} ms")
      Map.update(acc, key, [us], &(&1 ++ [us]))
    end)
  end)

result = %{
  scope:
    "Castlevania III captured hot loop, frozen PRG mapping in NROM, CPU-only; no live MMC5/PPU/APU/interrupts",
  instructions: instructions,
  block: block,
  compile_ms: %{generic: generic_compile / 1000, blocks: fused_compile / 1000},
  sequential: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  timings_us: times,
  variants: Map.new(variants, fn {name, _, stats} -> {name, stats} end),
  correctness:
    "final CPU registers/cycles and full RAM exact against native for each variant; synchronization included, upload/compile excluded"
}

File.write!(
  List.first(System.argv()) || "results/blocks_bench.json",
  IO.iodata_to_binary(:json.encode(result)) <> "\n"
)
