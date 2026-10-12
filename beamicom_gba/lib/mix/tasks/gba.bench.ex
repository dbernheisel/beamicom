defmodule Mix.Tasks.Gba.Bench do
  @moduledoc """
  Benchmarks GBA frame execution on the open diagnostic loop ROM or a supplied ROM.

      mix gba.bench --frames 30
      BEAMICOM_NX=1 mix gba.bench --rom game.gba --warmup 20 --frames 60
      BEAMICOM_NX=1 mix gba.bench --rom game.gba --executor scalar --no-fast-loops

  Timings include CPU execution, scheduler work, memory ownership, PPU rendering,
  and audio generation. This is a development signal, not a compatibility
  benchmark.
  """

  use Mix.Task

  alias Beamicom.GBA.{DiagnosticROM, Machine}

  @shortdoc "Benchmarks the GBA frame path"
  @switches [
    frames: :integer,
    warmup: :integer,
    rom: :string,
    executor: :string,
    fast_loops: :boolean,
    heap_words: :integer,
    binary_heap_words: :integer
  ]
  @clock_rate 16_777_216
  @frame_cycles 280_896
  @default_heap_words 800_000
  @default_binary_heap_words 65_536

  @impl true
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: @switches)
    frames = Keyword.get(opts, :frames, 30)
    warmup = Keyword.get(opts, :warmup, 0)
    heap_words = positive_option!(opts, :heap_words, @default_heap_words)
    binary_heap_words = positive_option!(opts, :binary_heap_words, @default_binary_heap_words)

    if frames <= 0, do: Mix.raise("--frames must be positive")
    if warmup < 0, do: Mix.raise("--warmup cannot be negative")

    :erlang.process_flag(:min_heap_size, heap_words)
    :erlang.process_flag(:min_bin_vheap_size, binary_heap_words)
    Mix.Task.run("app.start")

    load_opts = opts |> executor_options() |> fast_loop_options(opts)
    {:ok, machine} = opts[:rom] |> load_media() |> Machine.load(load_opts)
    machine = run_frames(machine, warmup)
    :erlang.garbage_collect()
    gc_before = :erlang.statistics(:garbage_collection)
    {timings, machine} = timed_frames(machine, frames)
    {garbage_collections, reclaimed_words} = gc_delta(gc_before)
    elapsed_microseconds = Enum.sum(timings)
    elapsed_seconds = elapsed_microseconds / 1_000_000
    emulated_seconds = frames * @frame_cycles / @clock_rate
    sorted = Enum.sort(timings)

    result = %{
      rom: opts[:rom] || :diagnostic,
      cpu_executor: machine.cpu_executor,
      fast_loops: machine.cpu.fast_loops?,
      cached_blocks: Machine.block_cache_size(machine),
      heap_words: heap_words,
      binary_heap_words: binary_heap_words,
      garbage_collections: garbage_collections,
      reclaimed_words: reclaimed_words,
      warmup_frames: warmup,
      frames: frames,
      elapsed_seconds: Float.round(elapsed_seconds, 6),
      emulated_seconds: Float.round(emulated_seconds, 6),
      average_frame_ms: Float.round(elapsed_microseconds / frames / 1_000, 3),
      median_frame_ms: Float.round(percentile(sorted, 0.5) / 1_000, 3),
      p95_frame_ms: Float.round(percentile(sorted, 0.95) / 1_000, 3),
      average_fps: Float.round(frames * 1_000_000 / elapsed_microseconds, 2),
      realtime_factor: Float.round(emulated_seconds / elapsed_seconds, 3),
      final_master_cycle: Machine.cycle(machine)
    }

    Mix.shell().info(inspect(result, pretty: true))
  end

  defp load_media(nil), do: DiagnosticROM.loop()

  defp load_media(path) do
    case File.read(path) do
      {:ok, media} ->
        media

      {:error, reason} ->
        Mix.raise("could not read ROM #{inspect(path)}: #{:file.format_error(reason)}")
    end
  end

  defp executor_options(opts), do: executor_option(opts[:executor])

  defp executor_option(nil), do: []
  defp executor_option("scalar"), do: [cpu_executor: :scalar]
  defp executor_option("decoded-blocks"), do: [cpu_executor: :decoded_blocks]

  defp executor_option(value),
    do: Mix.raise("--executor must be scalar or decoded-blocks, got: #{inspect(value)}")

  defp fast_loop_options(load_opts, opts) do
    if Keyword.has_key?(opts, :fast_loops),
      do: Keyword.put(load_opts, :fast_loops, opts[:fast_loops]),
      else: load_opts
  end

  defp run_frames(machine, 0), do: machine

  defp run_frames(machine, frames) do
    Enum.reduce(1..frames, machine, fn _frame, machine ->
      {:ok, machine, _number, _video, _sample_count, _pcm} =
        Machine.run_until_frame(machine)

      machine
    end)
  end

  defp timed_frames(machine, frames) do
    Enum.map_reduce(1..frames, machine, fn _frame, machine ->
      {elapsed, result} = :timer.tc(fn -> Machine.run_until_frame(machine) end)

      {:ok, machine, _number, _video, _sample_count, _pcm} = result
      {elapsed, machine}
    end)
  end

  defp percentile(sorted, percentile) do
    index = ceil(length(sorted) * percentile) - 1
    Enum.at(sorted, index)
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        Mix.raise(
          "--#{key |> Atom.to_string() |> String.replace("_", "-")} must be positive, got: #{inspect(value)}"
        )
    end
  end

  defp gc_delta({collections_before, words_before, _unused}) do
    {collections, words, _unused} = :erlang.statistics(:garbage_collection)
    {collections - collections_before, words - words_before}
  end
end
