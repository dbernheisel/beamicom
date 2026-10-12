defmodule Beamicom.GBA.Machine do
  @moduledoc """
  Coherent ownership boundary for GBA execution.

  CPU bus accesses advance the scheduler, PPU, DMA, and timers in hardware
  master cycles. Frame-boundary output combines mode-0/mode-3 video with
  timestamped PSG and Direct Sound audio rendered to deterministic stereo PCM.
  """

  alias Beamicom.GBA.{BIOS, Bus, CPU, Cartridge}
  alias Beamicom.GBA.CPU.BlockCache

  @clock_rate 16_777_216
  @frame_cycles 280_896
  @sample_rate 44_100
  @maximum_instructions_per_frame 2_000_000
  @default_cpu_executor Application.compile_env(
                          :beamicom_gba,
                          :cpu_executor,
                          :scalar
                        )
  @cpu_executors [:scalar, :decoded_blocks]

  @enforce_keys [:cpu, :bus, :cpu_executor, :block_cache]
  defstruct @enforce_keys ++ [audio_phase: 0]

  @doc "Loads media and creates either BIOS-entry or controlled skip-boot state."
  def load(media, opts \\ []) when is_binary(media) and is_list(opts) do
    with {:ok, cartridge} <- Cartridge.load(media, opts),
         {:ok, skip_boot, bios} <- boot_options(opts),
         {:ok, cpu_executor, block_cache, fast_loops?} <- execution_options(opts) do
      cpu_opts = [fast_loops: fast_loops?]
      cpu = if skip_boot, do: CPU.post_boot(cpu_opts), else: CPU.new(cpu_opts)
      bios = if skip_boot, do: BIOS.hle(), else: bios
      bus = Bus.new(cartridge, Keyword.put(opts, :bios, bios))

      {:ok,
       %__MODULE__{
         cpu: cpu,
         bus: bus,
         cpu_executor: cpu_executor,
         block_cache: block_cache
       }}
    end
  end

  @doc "Executes one scalar ARM7TDMI instruction."
  def step(%__MODULE__{} = machine) do
    case CPU.step_scalar(machine.cpu, machine.bus) do
      {:ok, cpu, bus, cycles} -> {:ok, %{machine | cpu: cpu, bus: bus}, cycles}
      {:error, reason, cpu, bus} -> {:error, reason, %{machine | cpu: cpu, bus: bus}}
    end
  end

  @doc "Returns the current hardware master cycle."
  def cycle(%__MODULE__{bus: bus}), do: Bus.cycle(bus)

  @doc false
  def block_cache_size(%__MODULE__{block_cache: block_cache}), do: BlockCache.size(block_cache)

  @doc false
  def default_cpu_executor, do: @default_cpu_executor

  @doc "Replaces the complete handheld button state."
  def set_buttons(%__MODULE__{} = machine, buttons) when is_list(buttons),
    do: %{machine | bus: Bus.set_buttons(machine.bus, buttons)}

  @doc "Runs until the next complete 280,896-cycle display frame."
  def run_until_frame(%__MODULE__{} = machine, limit \\ @maximum_instructions_per_frame)
      when is_integer(limit) and limit > 0 do
    target = machine.bus.ppu.frame_number

    case machine.cpu_executor do
      :scalar -> next_scalar_frame(machine, machine.cpu, machine.bus, target, limit)
      :decoded_blocks -> next_decoded_frame(machine, target, limit)
    end
  end

  defp next_scalar_frame(machine, cpu, bus, _target, 0),
    do: {:error, :frame_timeout, %{machine | cpu: cpu, bus: bus}}

  defp next_scalar_frame(machine, cpu, bus, target, remaining) do
    case CPU.run_scalar_until_frame(cpu, bus, target, remaining) do
      {:ok, cpu, bus, _executed} ->
        finish_frame(%{machine | cpu: cpu, bus: bus}, target)

      {:error, reason, cpu, bus, _executed} ->
        {:error, reason, %{machine | cpu: cpu, bus: bus}}
    end
  end

  defp next_decoded_frame(machine, _target, 0),
    do: {:error, :frame_timeout, machine}

  defp next_decoded_frame(machine, target, remaining) do
    next_decoded_frame(
      machine,
      machine.cpu,
      machine.bus,
      machine.block_cache,
      target,
      remaining
    )
  end

  defp next_decoded_frame(machine, cpu, bus, block_cache, _target, 0),
    do: {:error, :frame_timeout, %{machine | cpu: cpu, bus: bus, block_cache: block_cache}}

  defp next_decoded_frame(machine, cpu, bus, block_cache, target, remaining) do
    if BlockCache.cacheable?(cpu) do
      {block, block_cache} =
        BlockCache.fetch(block_cache, cpu, bus)

      case CPU.run_cached_block(cpu, bus, block, target, remaining) do
        {:ok, cpu, bus, executed} ->
          if bus.ppu.frame_number > target do
            finish_frame(
              %{machine | cpu: cpu, bus: bus, block_cache: block_cache},
              target
            )
          else
            next_decoded_frame(
              machine,
              cpu,
              bus,
              block_cache,
              target,
              remaining - executed
            )
          end

        {:error, reason, cpu, bus, _executed} ->
          {:error, reason, %{machine | cpu: cpu, bus: bus, block_cache: block_cache}}
      end
    else
      machine = %{machine | cpu: cpu, bus: bus, block_cache: block_cache}
      next_uncached_instruction(machine, cpu, bus, target, remaining)
    end
  end

  defp next_uncached_instruction(machine, cpu, bus, _target, 0),
    do: {:error, :frame_timeout, %{machine | cpu: cpu, bus: bus}}

  defp next_uncached_instruction(machine, cpu, bus, target, remaining) do
    case CPU.step(cpu, bus) do
      {:ok, cpu, bus, _cycles} ->
        machine = %{machine | cpu: cpu, bus: bus}

        cond do
          bus.ppu.frame_number > target ->
            finish_frame(machine, target)

          BlockCache.cacheable?(cpu) ->
            next_decoded_frame(machine, target, remaining - 1)

          true ->
            next_uncached_instruction(machine, cpu, bus, target, remaining - 1)
        end

      {:error, reason, cpu, bus} ->
        {:error, reason, %{machine | cpu: cpu, bus: bus}}
    end
  end

  defp finish_frame(machine, target) do
    {machine, sample_count, pcm} = take_audio(machine, target)
    {:ok, machine, target, machine.bus.ppu.frame, sample_count, pcm}
  end

  defp take_audio(machine, frame_number) do
    end_cycle = (frame_number + 1) * @frame_cycles

    {bus, sample_count, pcm, audio_phase} =
      Bus.take_audio(machine.bus, end_cycle, machine.audio_phase, @clock_rate, @sample_rate)

    {%{machine | bus: bus, audio_phase: audio_phase}, sample_count, pcm}
  end

  defp boot_options(opts) do
    skip_boot = Keyword.get(opts, :skip_boot, true)
    bios = Keyword.get(opts, :bios, <<>>)

    cond do
      not is_boolean(skip_boot) -> {:error, :invalid_skip_boot}
      not is_binary(bios) -> {:error, :invalid_bios}
      not skip_boot and byte_size(bios) != 16 * 1024 -> {:error, :bios_required}
      skip_boot -> {:ok, true, <<>>}
      true -> {:ok, false, bios}
    end
  end

  defp execution_options(opts) do
    cpu_executor = Keyword.get(opts, :cpu_executor, @default_cpu_executor)
    cache_limit = Keyword.get(opts, :block_cache_limit, 4_096)
    fast_loops? = Keyword.get(opts, :fast_loops, true)

    cond do
      cpu_executor not in @cpu_executors ->
        {:error, {:invalid_cpu_executor, cpu_executor}}

      not is_integer(cache_limit) or cache_limit < 0 ->
        {:error, {:invalid_block_cache_limit, cache_limit}}

      not is_boolean(fast_loops?) ->
        {:error, {:invalid_fast_loops, fast_loops?}}

      true ->
        {:ok, cpu_executor, BlockCache.new(limit: cache_limit), fast_loops?}
    end
  end
end
