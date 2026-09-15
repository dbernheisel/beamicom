defmodule Mix.Tasks.Nes.RecompileBench do
  @shortdoc "Benchmark the NES interpreter, mapper-0 generated dispatch, and RAM stores"
  @moduledoc """
  Usage:

      mix nes.recompile_bench ROM [--instructions 100000] [--ram-writes 1000000]

  Mapper-0 ROMs report interpreter and generated-block throughput. Other
  mappers report 100% fallback coverage instead of presenting an inapplicable
  generated speedup. The RAM microbenchmark compares the current 2 KiB
  binary-copy write with one `:atomics.put/3` per write.
  """

  use Mix.Task

  import Bitwise

  alias Beamicom.NES.{Cart, Console}
  alias Beamicom.NES.Recompiler.{Generator, Program}

  @impl true
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args, strict: [instructions: :integer, ram_writes: :integer])

    case {paths, invalid} do
      {[path], []} -> benchmark(path, options)
      _ -> Mix.raise("expected ROM [--instructions N] [--ram-writes N]")
    end
  end

  defp benchmark(path, options) do
    media = File.read!(path)
    {:ok, cart} = Cart.parse(media)
    instructions = Keyword.get(options, :instructions, 100_000)
    ram_writes = Keyword.get(options, :ram_writes, 1_000_000)

    if instructions < 1 or ram_writes < 1,
      do: Mix.raise("instruction and RAM-write counts must be positive")

    start = Console.load_binary(media)
    _warm = run_interpreter(start, min(instructions, 2_000))
    {interpreter_us, _console} = :timer.tc(fn -> run_interpreter(start, instructions) end)
    interpreter_ips = rate(instructions, interpreter_us)

    generated =
      case Generator.compile(cart) do
        {:ok, program} ->
          benchmark_generated(program, start, instructions, interpreter_ips)

        {:error, {:unsupported_mapper, mapper}} ->
          %{
            status: "unsupported_mapper",
            mapper: mapper,
            static_instructions: 0,
            fallback_percent: 100.0,
            measured_speedup: :null
          }
      end

    result = %{
      rom: Path.basename(path),
      rom_sha256: Base.encode16(:crypto.hash(:sha256, media), case: :lower),
      mapper: cart.mapper,
      requested_instructions: instructions,
      interpreter: %{wall_us: interpreter_us, instructions_per_second: interpreter_ips},
      generated: generated,
      ram_store_microbenchmark: ram_benchmark(ram_writes),
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release))
    }

    IO.puts(:json.encode(result))
  end

  defp benchmark_generated(program, start, target, interpreter_ips) do
    {_warm_console, _warm_count} = run_generated(program, start, min(target, 2_000))
    stats_before = Program.statistics(program)

    {wall_us, {_console, executed}} =
      :timer.tc(fn -> run_generated(program, start, target) end)

    stats_after = Program.statistics(program)
    compiled = stats_after.compiled_instructions - stats_before.compiled_instructions
    fallback = stats_after.fallback_instructions - stats_before.fallback_instructions
    measured = rate(executed, wall_us)

    %{
      status: "ok",
      wall_us: wall_us,
      executed_instructions: executed,
      instructions_per_second: measured,
      measured_speedup: measured / interpreter_ips,
      discovered_blocks: map_size(program.discovery.blocks),
      static_instructions: map_size(program.discovery.instructions),
      compiled_instructions: compiled,
      fallback_instructions: fallback,
      fallback_percent: percent(fallback, compiled + fallback)
    }
  end

  defp run_interpreter(console, count) do
    Enum.reduce(1..count, console, fn _, console -> Console.step(console) end)
  end

  defp run_generated(program, console, target), do: run_generated(program, console, target, 0)

  defp run_generated(_program, console, target, count) when count >= target,
    do: {console, count}

  defp run_generated(program, console, target, count) do
    {console, block_count} = Program.step(program, console)
    run_generated(program, console, target, count + block_count)
  end

  defp ram_benchmark(count) do
    binary = <<0::size(0x800 * 8)>>
    atomics = :atomics.new(0x800, signed: false)

    {binary_us, binary} =
      :timer.tc(fn ->
        Enum.reduce(0..(count - 1), binary, fn n, ram ->
          index = rem(n, 0x800)
          <<prefix::binary-size(^index), _old, suffix::binary>> = ram
          <<prefix::binary, n &&& 0xFF, suffix::binary>>
        end)
      end)

    {atomics_us, :ok} =
      :timer.tc(fn ->
        Enum.each(0..(count - 1), fn n ->
          :atomics.put(atomics, rem(n, 0x800) + 1, n &&& 0xFF)
        end)
      end)

    # Force both results to remain live through the timed loops.
    true = :binary.at(binary, rem(count - 1, 0x800)) == (count - 1 &&& 0xFF)
    true = :atomics.get(atomics, rem(count - 1, 0x800) + 1) == (count - 1 &&& 0xFF)

    %{
      writes: count,
      binary_copy: %{wall_us: binary_us, writes_per_second: rate(count, binary_us)},
      atomics: %{wall_us: atomics_us, writes_per_second: rate(count, atomics_us)},
      atomics_speedup: binary_us / atomics_us
    }
  end

  defp rate(count, microseconds), do: count * 1_000_000 / max(microseconds, 1)
  defp percent(_part, 0), do: 0.0
  defp percent(part, total), do: part * 100.0 / total
end
