NxNes.Reference.load()
alias NxNes.{APU, PackedAPU, Batch}
data = File.read!("tmp/devices.etf") |> :erlang.binary_to_term()
{seed, _} = Enum.find(data.apu, fn {s, _} -> s.m5_active and s.pulse1.length > 0 end)
seed = %{seed | samples: []}
initial = APU.pack(seed) |> Batch.resident()
cycles = Nx.tensor(29830, type: :s32) |> Batch.resident()

ref_run = fn ->
  Enum.reduce(1..64, {seed, []}, fn _, {s, chunks} ->
    next = NxNes.ReferenceAPU.run(s, 29830)
    {_, pcm, next} = Beamicom.NES.APU.take_pcm(next)
    {next, [pcm | chunks]}
  end)
end

{ref_final, ref_pcm} = ref_run.()

results =
  for {name, state, kernel} <- [
        {:scalar_state, initial, &APU.run/2},
        {:packed_state, PackedAPU.pack(initial), &PackedAPU.run/2}
      ] do
    {compile_us, fun} =
      :timer.tc(fn ->
        EXLA.compile(kernel, [Nx.to_template(state), Nx.to_template(cycles)], client: :host)
      end)

    run = fn ->
      Enum.reduce(1..64, {state, []}, fn _, {s, chunks} ->
        {s, pcm, count, left} = fun.(s, cycles)
        if Nx.to_number(left) != 0, do: raise("unconsumed cycles")
        pcm = Nx.to_binary(pcm) |> binary_part(0, Nx.to_number(count) * 2)
        {s, [pcm | chunks]}
      end)
    end

    {final, pcm} = run.()
    if pcm != ref_pcm, do: raise("#{name}: PCM differs")
    final = if name == :packed_state, do: PackedAPU.unpack(final), else: final

    flatten = fn recurse, map ->
      Enum.flat_map(map, fn {k, v} ->
        if is_struct(v, Nx.Tensor),
          do: [{[k], Nx.to_number(v)}],
          else: Enum.map(recurse.(recurse, v), fn {path, value} -> {[k | path], value} end)
      end)
    end

    expected = flatten.(flatten, APU.pack(ref_final)) |> Map.new()

    for {path, actual} <- flatten.(flatten, final) do
      e = Map.fetch!(expected, path)
      if abs(actual - e) > 1.0e-12, do: raise("#{name}: state differs #{inspect(path)}")
    end

    %{variant: name, compile_ms: compile_us / 1000, run: run}
  end

native_initial = NxNes.NativeAPU.pack(seed)

native_run = fn ->
  Enum.reduce(1..64, {native_initial, []}, fn _, {s, chunks} ->
    {s, pcm, 0} = NxNes.NativeAPU.run(s, 29830)
    {s, [pcm | chunks]}
  end)
end

{native_final, native_pcm} = native_run.()
if native_pcm != ref_pcm, do: raise("native: PCM differs")

compare = fn rec, actual, expected ->
  for {k, e} <- NxNes.NativeAPU.fields(expected) do
    a = Map.fetch!(actual, k)

    cond do
      is_struct(e) -> rec.(rec, a, e)
      is_float(e) -> if abs(a - e) > 1.0e-12, do: raise("native state differs: #{k}")
      true -> if a != e, do: raise("native state differs: #{k}")
    end
  end
end

compare.(compare, NxNes.NativeAPU.unpack(native_final), ref_final)
# Compile and warm every implementation first, then rotate measurement order.
runners =
  [{:reference, ref_run}, {:native, native_run}] ++ Enum.map(results, &{&1.variant, &1.run})

Enum.each(runners, fn {_, fun} -> fun.() end)

timings =
  Enum.reduce(0..6, %{}, fn round, acc ->
    {first, rest} = Enum.split(runners, rem(round, length(runners)))

    Enum.reduce(rest ++ first, acc, fn {name, fun}, acc ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      Map.update(acc, name, [us], &(&1 ++ [us]))
    end)
  end)

reference = timings.reference
native_times = timings.native

results =
  Enum.map(results, fn r ->
    r |> Map.delete(:run) |> Map.put(:wall_us, Map.fetch!(timings, r.variant))
  end)

# Replay every captured event, including changes made by the game's register writes.
# These independent snapshots validate coverage, not continuous-game speed.
for {s, dc} <- data.apu do
  expected = NxNes.ReferenceAPU.advance(%{s | samples: []}, dc)
  {_, expected_pcm, expected} = Beamicom.NES.APU.take_pcm(expected)
  {actual, pcm, 0} = NxNes.NativeAPU.run(NxNes.NativeAPU.pack(s), dc)
  if pcm != expected_pcm, do: raise("native captured-event PCM differs")
  compare.(compare, NxNes.NativeAPU.unpack(actual), expected)
end

result = %{
  scope:
    "64 continuous APU intervals seeded from Castlevania; no intervening register writes; PCM export included",
  xla_flags: System.get_env("XLA_FLAGS", ""),
  diagnostic_sequential_thunks: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  diagnostic_preload: System.get_env("LD_PRELOAD", ""),
  timing_method: "7 rounds, rotating implementation order after compilation and warmup",
  intervals: 64,
  cycles_per_interval: 29830,
  reference_us: reference,
  nx: results,
  native_us: native_times,
  native_captured_events_verified: length(data.apu),
  native_state_bytes: byte_size(native_initial),
  pcm_sha256:
    Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(Enum.reverse(ref_pcm))), case: :lower),
  correctness: "PCM exact, integer state exact, floating state within 1e-12"
}

File.write!(
  List.first(System.argv()) || "results/apu_native.json",
  IO.iodata_to_binary(:json.encode(result)) <> "\n"
)

IO.inspect(result)
