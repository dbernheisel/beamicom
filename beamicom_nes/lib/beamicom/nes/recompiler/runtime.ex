defmodule Beamicom.NES.Recompiler.Runtime do
  @moduledoc false

  alias Beamicom.NES.{CPU, Console}
  alias Beamicom.NES.Recompiler.MMC5Profile

  @doc false
  def run_block(a, x, y, sp, p, cycles, ram, {%CPU{} = cpu, bus}, addresses)
      when is_binary(ram) and is_list(addresses) do
    cpu = %{cpu | a: a, x: x, y: y, sp: sp, p: p, cycles: cycles}
    bus = %{bus | ram: ram}
    {cpu, bus, count} = run_instructions(cpu, bus, addresses, frame_number(bus), 0)
    {%Console{cpu: cpu, bus: bus}, count}
  end

  @doc false
  def run_block(a, x, y, sp, p, cycles, ram, {%CPU{} = cpu, bus}, addresses, signature)
      when is_binary(ram) and is_list(addresses) do
    cpu = %{cpu | a: a, x: x, y: y, sp: sp, p: p, cycles: cycles}
    bus = %{bus | ram: ram}
    {cpu, bus, count} =
      run_mmc5_instructions(cpu, bus, addresses, signature, frame_number(bus), 0)
    {%Console{cpu: cpu, bus: bus}, count}
  end

  @doc false
  def fallback(%Console{} = console), do: {Console.step(console), 1}

  # An interrupt may redirect PC after any instruction. Stop immediately rather
  # than executing the remainder of the statically discovered straight-line
  # block; the next dispatch will select the interrupt target or fall back.
  defp run_instructions(cpu, bus, [], _frame, count), do: {cpu, bus, count}

  defp run_instructions(
         %CPU{pc: pc} = cpu,
         bus,
         [{pc, operation, mode, base_cycles} | rest],
         frame,
         count
       ) do
    {cpu, bus} = CPU.step_known(cpu, bus, operation, mode, base_cycles)

    if frame_number(bus) == frame,
      do: run_instructions(cpu, bus, rest, frame, count + 1),
      else: {cpu, bus, count + 1}
  end

  defp run_instructions(cpu, bus, _instructions, _frame, count) when count > 0,
    do: {cpu, bus, count}

  defp run_mmc5_instructions(cpu, bus, [], _signature, _frame, count), do: {cpu, bus, count}

  defp run_mmc5_instructions(
         %CPU{pc: pc} = cpu,
         bus,
         [{pc, operation, mode, base_cycles} | rest],
         signature,
         frame,
         count
       ) do
    if MMC5Profile.signature(bus) == signature and MMC5Profile.rom_address?(signature, pc) do
      {cpu, bus} = CPU.step_known(cpu, bus, operation, mode, base_cycles)

      if frame_number(bus) == frame,
        do: run_mmc5_instructions(cpu, bus, rest, signature, frame, count + 1),
        else: {cpu, bus, count + 1}
    else
      {cpu, bus, count}
    end
  end

  defp run_mmc5_instructions(cpu, bus, _instructions, _signature, _frame, count) when count > 0,
    do: {cpu, bus, count}

  defp frame_number(%{ppu: nil}), do: nil
  defp frame_number(%{ppu: %{frame_ready: nil}}), do: nil
  defp frame_number(%{ppu: %{frame_ready: %{number: number}}}), do: number
end
