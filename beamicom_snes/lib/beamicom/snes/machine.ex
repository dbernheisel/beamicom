defmodule Beamicom.SNES.Machine do
  @moduledoc "Coherent cartridge, bus, timing, and 65C816 ownership boundary."

  alias Beamicom.SNES.{Bus, CPU, Cartridge}

  @max_instructions_per_frame 1_000_000

  @enforce_keys [:cartridge, :cpu, :bus]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec load(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(media, opts \\ []) when is_binary(media) and is_list(opts) do
    with {:ok, cartridge} <- Cartridge.load(media) do
      bus = Bus.new(cartridge, opts)
      {:ok, %__MODULE__{cartridge: cartridge, cpu: CPU.reset(bus), bus: bus}}
    end
  end

  @spec step(t()) :: {:ok, t(), pos_integer()} | {:error, term(), t()}
  def step(%__MODULE__{cpu: cpu, bus: bus} = machine) do
    case CPU.step(cpu, bus) do
      {:ok, cpu, bus, clocks} -> {:ok, %{machine | cpu: cpu, bus: bus}, clocks}
      {:error, reason, cpu, bus} -> {:error, reason, %{machine | cpu: cpu, bus: bus}}
    end
  end

  @doc "Runs until the next native PPU frame is complete."
  @spec run_until_frame(t(), pos_integer()) ::
          {:ok, t(), Beamicom.SNES.PPU.frame()} | {:error, term(), t()}
  def run_until_frame(%__MODULE__{} = machine, limit \\ @max_instructions_per_frame)
      when is_integer(limit) and limit > 0 do
    next_frame(machine.cpu, machine.bus, machine.bus.ppu.frame_number, limit, machine)
  end

  @doc "Drains audio accumulated on the shared master-clock timeline."
  def take_audio_pcm(%__MODULE__{bus: bus} = machine) do
    {frames, pcm, bus} = Bus.take_audio_pcm(bus)
    {frames, pcm, %{machine | bus: bus}}
  end

  defp next_frame(cpu, bus, _target, 0, machine),
    do: {:error, :frame_timeout, %{machine | cpu: sync_cpu_clock(cpu, bus), bus: bus}}

  defp next_frame(cpu, bus, target, remaining, machine) do
    case CPU.step_deferred(cpu, bus) do
      {:ok, cpu, %{ppu: %{frame_number: frame_number}} = bus} when frame_number > target ->
        {frame, bus} = Bus.take_frame(bus)
        {:ok, %{machine | cpu: sync_cpu_clock(cpu, bus), bus: bus}, frame}

      {:ok, cpu, bus} ->
        next_frame(cpu, bus, target, remaining - 1, machine)

      {:error, reason, cpu, bus} ->
        {:error, reason, %{machine | cpu: sync_cpu_clock(cpu, bus), bus: bus}}
    end
  end

  defp sync_cpu_clock(cpu, bus), do: %{cpu | master_clocks: Bus.cpu_master_clocks(bus)}
end
