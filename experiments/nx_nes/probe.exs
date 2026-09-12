defmodule ResidentProbe do
  alias NxNes.HotLoop
  alias Beamicom.NES.CPU

  def run(path) do
    media = File.read!(path)
    {top, snapshots} = File.read!("tmp/hot_snapshots.etf") |> :erlang.binary_to_term()
    # Find a loop entry by validating instruction shape, not by assuming a ROM revision.
    {key, cpu, bus, initial} =
      Enum.find_value(top, fn {key, _} ->
        {cpu, bus} = Map.fetch!(snapshots, key)

        try do
          initial = HotLoop.load(media, cpu, bus)
          {key, cpu, bus, initial}
        rescue
          ArgumentError -> nil
        end
      end) || raise "no supported hot loop found"

    IO.puts("Selected hot loop at #{Integer.to_string(cpu.pc, 16)}")

    {compile_us, compiled} =
      :timer.tc(fn ->
        EXLA.compile(&HotLoop.run/2, [Nx.to_template(initial), Nx.template({}, :s64)],
          client: :host
        )
      end)

    for n <- [1, 2, 127, 256, 1000] do
      expected = reference(cpu, bus, n * 6)
      actual = compiled.(initial, HotLoop.scalar(n))
      assert_equal!(actual, expected)
    end

    iterations = 65_536
    expected = reference(cpu, bus, iterations * 6)

    reference_runs =
      for _ <- 1..3 do
        {us, actual} = :timer.tc(fn -> reference(cpu, bus, iterations * 6) end)
        if actual != expected, do: raise("reference diverged")
        us
      end

    specialized_runs =
      for _ <- 1..3 do
        {us, actual} = :timer.tc(fn -> NxNes.ElixirLoop.run(cpu, bus, iterations) end)
        if actual != expected, do: raise("specialized Elixir diverged")
        us
      end

    cases =
      for batch <- [1, 16, 256, 4096, 65_536] do
        count = HotLoop.scalar(batch) |> Nx.backend_copy({EXLA.Backend, client: :host})
        # Warm execution, force completion, and verify outside timing.
        compiled.(initial, count) |> Map.fetch!(:ram) |> Nx.to_binary()

        runs =
          for _ <- 1..3 do
            :erlang.garbage_collect()

            {us, state} =
              :timer.tc(fn ->
                state =
                  Enum.reduce(1..div(iterations, batch), initial, fn _, s ->
                    compiled.(s, count)
                  end)

                # EXLA is asynchronous: synchronize RAM and cycle output inside the timer.
                Nx.to_binary(state.ram)
                Nx.to_number(state.cycles)
                state
              end)

            assert_equal!(state, expected)
            if Nx.to_binary(state.rom) != media, do: raise("ROM changed")
            if Nx.to_binary(state.wram) != Nx.to_binary(initial.wram), do: raise("WRAM changed")
            us
          end

        %{
          iterations_per_call: batch,
          calls: div(iterations, batch),
          wall_us: runs,
          median_speedup_vs_headless_interpreter: median(reference_runs) / median(runs),
          median_speedup_vs_specialized_elixir: median(specialized_runs) / median(runs)
        }
      end

    result = %{
      scope: "CPU-only six-instruction hot loop; no PPU/APU/interrupts; NOT full-game speedup",
      entry_pc: elem(key, 0),
      iterations: iterations,
      instructions: iterations * 6,
      rom_bytes: byte_size(media),
      ram_bytes: 2048,
      wram_tensor_bytes: 65536,
      backend: "EXLA host",
      compile_ms: compile_us / 1000,
      nx: Application.spec(:nx, :vsn) |> to_string(),
      exla: Application.spec(:exla, :vsn) |> to_string(),
      reference_wall_us: reference_runs,
      specialized_elixir_wall_us: specialized_runs,
      cases: cases,
      correctness: "registers, cycles, RAM matched"
    }

    json = IO.iodata_to_binary(:json.encode(result))
    File.write!("results/resident_probe.json", json <> "\n")
    IO.puts(json)
  end

  defp reference(cpu, bus, 0), do: {cpu, bus}

  defp reference(cpu, bus, n) do
    {cpu, bus} = CPU.step(cpu, bus)
    reference(cpu, bus, n - 1)
  end

  defp assert_equal!(s, {cpu, bus}) do
    for k <- [:a, :x, :y, :sp, :pc, :p, :cycles] do
      if Nx.to_number(Map.fetch!(s, k)) != Map.fetch!(cpu, k), do: raise("CPU mismatch: #{k}")
    end

    if Nx.to_binary(s.ram) != bus.ram, do: raise("RAM mismatch")
  end

  defp median(xs), do: xs |> Enum.sort() |> Enum.at(1)
end

ResidentProbe.run(hd(System.argv()))
