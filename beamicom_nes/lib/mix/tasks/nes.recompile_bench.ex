defmodule Mix.Tasks.Nes.RecompileBench do
  @shortdoc "Benchmark the NES interpreter, mapper-0 generated dispatch, and RAM stores"
  @moduledoc """
  Usage:

      mix nes.recompile_bench ROM [--instructions 100000] [--profile-instructions 250000]
                                  [--ram-writes 1000000]

  Mapper-0 ROMs use vector-root recursive discovery. MMC5 ROMs first run the
  interpreter for the requested profile interval, then compile the observed PRG
  mappings; unobserved mappings and executable PRG-RAM fall back. Other mappers
  report 100% fallback coverage. The RAM microbenchmark compares the current
  2 KiB binary-copy write with one `:atomics.put/3` per write.
  """

  use Mix.Task

  import Bitwise

  alias Beamicom.NES.{Cart, Console}
  alias Beamicom.NES.Recompiler.{Generator, MMC5Profile, Program}

  @impl true
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args,
        strict: [instructions: :integer, profile_instructions: :integer, ram_writes: :integer]
      )

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
    profile_instructions = Keyword.get(options, :profile_instructions, 250_000)

    if instructions < 1 or profile_instructions < 1 or ram_writes < 1,
      do: Mix.raise("instruction and RAM-write counts must be positive")

    start = Console.load_binary(media)
    _warm = run_interpreter(start, min(instructions, 2_000))
    {interpreter_us, _console} = :timer.tc(fn -> run_interpreter(start, instructions) end)
    interpreter_ips = rate(instructions, interpreter_us)

    {compile_us, compile_result} =
      :timer.tc(fn -> compile(cart, start, profile_instructions) end)

    generated =
      case compile_result do
        {:ok, program} ->
          benchmark_generated(program, start, instructions, interpreter_ips)
          |> Map.put(:compile_wall_us, compile_us)

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
      profile_instructions: if(cart.mapper == 5, do: profile_instructions, else: 0),
      interpreter: %{wall_us: interpreter_us, instructions_per_second: interpreter_ips},
      generated: generated,
      ram_store_microbenchmark: ram_benchmark(ram_writes),
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release))
    }

    IO.puts(:json.encode(result))
  end

  defp compile(%Cart{mapper: 5} = cart, start, profile_instructions) do
    with {:ok, profile, _console} <- MMC5Profile.capture(start, profile_instructions),
         {:ok, program} <- Generator.compile(cart, profile) do
      {:ok, %{program | discovery: Map.put(program.discovery, :profile, profile)}}
    end
  end

  defp compile(cart, _start, _profile_instructions), do: Generator.compile(cart)

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
    |> maybe_profile_stats(program.discovery)
  end

  defp maybe_profile_stats(result, %{mapper: 5, profile: profile}) do
    Map.put(result, :profile, %{
      mapping_signatures: MapSet.size(profile.signatures),
      mapping_changes: profile.mapping_changes,
      hot_instruction_identities: map_size(profile.hits)
    })
  end

  defp maybe_profile_stats(result, _discovery), do: result

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
