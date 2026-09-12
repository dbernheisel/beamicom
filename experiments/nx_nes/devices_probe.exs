defmodule DevicesProbe do
  alias NxNes.{Batch, PPU, APU}

  def run do
    NxNes.Reference.load()
    data = File.read!("tmp/devices.etf") |> :erlang.binary_to_term()
    chr = Nx.from_binary(data.chr, :u8) |> Batch.resident()
    ppu_inputs = Enum.map(data.ppu, &PPU.pack/1)

    ppu_reference = fn samples ->
      Enum.map(samples, fn s ->
        s = struct(Beamicom.NES.PPU, Map.merge(s, %{chr: data.chr, fb: [], frame_ready: nil}))
        result = NxNes.ReferencePPU.render_scanline(s)
        {hd(result.fb), result.status, result.v}
      end)
    end

    expected_ppu = ppu_reference.(data.ppu)

    ppu_results =
      for batch <- [1, 8, 240] do
        inputs = Enum.chunk_every(ppu_inputs, batch) |> Enum.map(&Batch.stack/1)
        [first | _] = inputs

        {compile_us, fun} =
          :timer.tc(fn ->
            EXLA.compile(&PPU.render/2, [Nx.to_template(first), Nx.to_template(chr)],
              client: :host
            )
          end)

        resident = Enum.map(inputs, &Batch.resident/1)

        actual =
          Enum.flat_map(resident, fn s ->
            {pixels, status, v} = Batch.host(fun.(s, chr))
            bytes = Nx.to_binary(pixels)
            lines = for <<line::binary-size(256) <- bytes>>, do: line
            Enum.zip([lines, Nx.to_flat_list(status), Nx.to_flat_list(v)])
          end)

        Enum.zip(actual, expected_ppu)
        |> Enum.with_index()
        |> Enum.each(fn {{a, e}, i} ->
          if a != e,
            do:
              raise(
                "PPU mismatch at captured line #{i}: status/v #{inspect({elem(a, 1), elem(a, 2), elem(e, 1), elem(e, 2)})}; pixels match #{elem(a, 0) == elem(e, 0)}"
              )
        end)

        timings = measure(fn -> Enum.each(resident, fn s -> Batch.host(fun.(s, chr)) end) end)

        transfer_timings =
          measure(fn ->
            Enum.each(inputs, fn s -> Batch.host(fun.(Batch.resident(s), chr)) end)
          end)

        %{
          batch_lines: batch,
          compile_ms: compile_us / 1000,
          resident_us: timings,
          with_upload_us: transfer_timings
        }
      end

    ppu_ref_us = measure(fn -> ppu_reference.(data.ppu) end)
    IO.inspect(%{ppu_reference_us: ppu_ref_us, ppu: ppu_results})

    apu_inputs =
      Enum.map(data.apu, fn {s, dc} -> %{state: APU.pack(s), dc: Nx.tensor(dc, type: :s32)} end)

    apu_reference = fn ->
      Enum.map(data.apu, fn {s, dc} -> NxNes.ReferenceAPU.advance(s, dc) end)
    end

    expected_apu = apu_reference.()

    # Sampled event steps, not a chronological simulation: each input contains its true prior state.
    apu_results =
      for batch <- [1, 32, 256] do
        # Pad the final batch, then discard its extra outputs during comparison.
        inputs =
          Enum.chunk_every(
            apu_inputs,
            batch,
            batch,
            List.duplicate(List.last(apu_inputs), batch - 1)
          )
          |> Enum.map(&Batch.stack/1)

        [first | _] = inputs

        {compile_us, fun} =
          :timer.tc(fn ->
            EXLA.compile(fn s -> APU.advance(s.state, s.dc) end, [Nx.to_template(first)],
              client: :host
            )
          end)

        resident = Enum.map(inputs, &Batch.resident/1)
        # Validate every captured state once in the widest batch. Scalar semantics
        # and resident recurrence are also covered by the differential test suite.
        for {s, index} <- Enum.with_index(resident), batch == 256 do
          {actual, pcm, counts} = Batch.host(fun.(s))
          n = min(batch, length(expected_apu) - index * batch)
          refs = Enum.slice(expected_apu, index * batch, n)
          refs = refs ++ List.duplicate(List.last(refs), batch - n)
          expected = Enum.map(refs, &APU.pack/1) |> Batch.stack() |> Batch.host()
          compare_state(actual, expected, n, [])
          actual_pcm = Nx.to_flat_list(pcm) |> Enum.take(n)
          expected_pcm = Enum.map(Enum.take(refs, n), fn a -> List.first(a.samples) || 0 end)
          if actual_pcm != expected_pcm, do: raise("APU PCM mismatch in batch #{index}")
          actual_counts = Nx.to_flat_list(counts) |> Enum.take(n)

          if actual_counts != Enum.map(Enum.take(refs, n), &length(&1.samples)),
            do: raise("sample count mismatch")
        end

        # Normal output only: hardware state remains on EXLA, not exported per event.
        timings =
          measure(fn -> Enum.each(resident, fn s -> fun.(s) |> elem(1) |> Nx.to_binary() end) end)

        transfer_timings =
          measure(fn ->
            Enum.each(inputs, fn s -> fun.(Batch.resident(s)) |> elem(1) |> Nx.to_binary() end)
          end)

        %{
          batch_segments: batch,
          compile_ms: compile_us / 1000,
          resident_us: timings,
          with_upload_us: transfer_timings
        }
      end

    apu_ref_us = measure(apu_reference)
    {seed, _} = Enum.find(data.apu, fn {s, _} -> s.m5_active and s.pulse1.length > 0 end)
    seed = %{seed | samples: []}
    initial = APU.pack(seed) |> Batch.resident()
    cycles = Nx.tensor(29830, type: :s32) |> Batch.resident()

    {continuous_compile_us, continuous_fun} =
      :timer.tc(fn ->
        EXLA.compile(&APU.run/2, [Nx.to_template(initial), Nx.to_template(cycles)], client: :host)
      end)

    ref_run = fn ->
      Enum.reduce(1..64, {seed, []}, fn _, {s, chunks} ->
        next = NxNes.ReferenceAPU.run(%{s | samples: []}, 29830)
        {next, [Enum.reverse(next.samples) | chunks]}
      end)
    end

    nx_run = fn ->
      Enum.reduce(1..64, {initial, []}, fn _, {s, chunks} ->
        {next, pcm, count, left} = continuous_fun.(s, cycles)
        if Nx.to_number(left) != 0, do: raise("unexpected full APU output buffer")
        pcm = Nx.to_binary(pcm) |> binary_part(0, Nx.to_number(count) * 2)
        {next, [pcm | chunks]}
      end)
    end

    {ref_final, ref_chunks} = ref_run.()

    expected_pcm =
      ref_chunks
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.map(fn x -> <<x::signed-little-16>> end)
      |> IO.iodata_to_binary()

    {nx_final, nx_chunks} = nx_run.()
    actual_pcm = nx_chunks |> Enum.reverse() |> IO.iodata_to_binary()
    if actual_pcm != expected_pcm, do: raise("continuous APU PCM diverged")
    compare_state(Batch.host(nx_final), APU.pack(ref_final), 1, [])

    continuous = %{
      intervals: 64,
      cycles_per_interval: 29830,
      register_writes: false,
      compile_ms: continuous_compile_us / 1000,
      reference_us: measure(ref_run),
      nx_us: measure(nx_run),
      pcm_sha256: Base.encode16(:crypto.hash(:sha256, actual_pcm), case: :lower)
    }

    result = %{
      rom_sha256: data.rom_sha256,
      ppu_lines: length(data.ppu),
      apu_segments: length(data.apu),
      ppu_reference_us: ppu_ref_us,
      ppu: ppu_results,
      apu_reference_us: apu_ref_us,
      apu: apu_results,
      continuous_apu: continuous,
      scope:
        "Captured device event replay, not full-core speedup. Resident timings include output synchronization. Upload timings include prepacked tensor transfers, not state packing.",
      correctness:
        "PPU pixels/status/scroll exact; APU PCM/counts/integers exact, float state within 1e-12"
    }

    File.write!("results/devices_probe.json", IO.iodata_to_binary(:json.encode(result)) <> "\n")
    IO.inspect(result)
  end

  defp compare_state(%Nx.Tensor{} = a, %Nx.Tensor{} = e, n, path) do
    a = if(Nx.rank(a) == 0, do: a, else: Nx.slice_along_axis(a, 0, n)) |> Nx.to_flat_list()
    e = if(Nx.rank(e) == 0, do: e, else: Nx.slice_along_axis(e, 0, n)) |> Nx.to_flat_list()

    Enum.zip(a, e)
    |> Enum.each(fn {x, y} ->
      if (is_float(y) and abs(x - y) > 1.0e-12) or (is_integer(y) and x != y),
        do: raise("APU state mismatch #{inspect(Enum.reverse(path))}: #{x} != #{y}")
    end)
  end

  defp compare_state(a, e, n, path),
    do: Enum.each(e, fn {k, v} -> compare_state(Map.fetch!(a, k), v, n, [k | path]) end)

  defp measure(fun) do
    fun.()

    for _ <- 1..3 do
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      us
    end
  end
end

DevicesProbe.run()
