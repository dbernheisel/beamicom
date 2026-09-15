defmodule Beamicom.NES.Recompiler.MMC5Discovery do
  @moduledoc """
  Recursive-descent discovery over profiled MMC5 PRG-ROM mappings.

  Instructions are keyed by `{mapping_signature, cpu_address}`. Mapping writes
  are safe even when discovery follows the old mapping past them: the generated
  runtime checks the live signature before every instruction and yields as soon
  as a bank register changes.
  """

  import Bitwise

  alias Beamicom.NES.{CPU, Cart}
  alias Beamicom.NES.Recompiler.MMC5Profile

  @branches [:BCC, :BCS, :BEQ, :BMI, :BNE, :BPL, :BVC, :BVS]
  @terminal_operations [:BRK, :RTI, :RTS]
  @operand_bytes %{
    imp: 0,
    acc: 0,
    imm: 1,
    zp: 1,
    zpx: 1,
    zpy: 1,
    rel: 1,
    abs: 2,
    abx: 2,
    aby: 2,
    ind: 2,
    izx: 1,
    izy: 1
  }

  @doc "Discover code under every mapping captured by `MMC5Profile`."
  def discover(%Cart{mapper: 5, prg_rom: prg}, %{mapper: 5, roots: roots} = profile) do
    discoveries =
      roots
      |> Enum.sort_by(fn {signature, _roots} -> signature end)
      |> Enum.map(fn {signature, entries} ->
        observed =
          profile.hits
          |> Enum.flat_map(fn
            {{^signature, address}, _count} -> [address]
            {_key, _count} -> []
          end)
          |> MapSet.new()

        {signature, discover_signature(prg, signature, MapSet.to_list(entries), observed)}
      end)
      |> Map.new()

    instructions =
      discoveries
      |> Enum.flat_map(fn {_signature, discovery} -> Map.to_list(discovery.instructions) end)
      |> Map.new()

    blocks =
      discoveries
      |> Enum.flat_map(fn {_signature, discovery} -> Map.to_list(discovery.blocks) end)
      |> Map.new()

    {:ok,
     %{
       mapper: 5,
       prg_size: byte_size(prg),
       profile: profile,
       signatures: discoveries,
       instructions: instructions,
       blocks: blocks,
       block_starts: blocks |> Map.keys() |> Enum.sort(),
       instruction_bytes:
         instructions
         |> Map.values()
         |> Enum.map(& &1.physical_offset)
         |> MapSet.new()
         |> MapSet.size()
     }}
  end

  def discover(%Cart{mapper: mapper}, _profile), do: {:error, {:unsupported_mapper, mapper}}

  defp discover_signature(prg, signature, entries, observed) do
    queue = entries |> Enum.uniq() |> :queue.from_list()
    {instructions, dynamic_exits} = walk(prg, signature, observed, queue, %{}, [])
    starts = block_starts(signature, entries, instructions)

    %{
      signature: signature,
      roots: Enum.sort(entries),
      instructions: instructions,
      blocks: build_blocks(signature, starts, instructions),
      dynamic_exits: Enum.reverse(dynamic_exits)
    }
  end

  defp walk(prg, signature, observed, queue, instructions, exits) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {instructions, exits}

      {{:value, address}, queue} ->
        key = {signature, address}

        cond do
          not MapSet.member?(observed, address) or
              not MMC5Profile.rom_address?(signature, address) or Map.has_key?(instructions, key) ->
            walk(prg, signature, observed, queue, instructions, exits)

          true ->
            instruction = decode(prg, signature, address)
            instructions = Map.put(instructions, key, instruction)

            queue =
              Enum.reduce(instruction.successors, queue, fn %{address: successor}, acc ->
                if MapSet.member?(observed, successor) and
                     MMC5Profile.rom_address?(signature, successor),
                  do: :queue.in(successor, acc),
                  else: acc
              end)

            exits =
              case instruction.dynamic_exit do
                nil -> exits
                reason -> [%{address: address, reason: reason} | exits]
              end

            walk(prg, signature, observed, queue, instructions, exits)
        end
    end
  end

  defp decode(prg, signature, address) do
    opcode = read8(prg, signature, address)
    {operation, mode, cycles} = CPU.opcode_info(opcode)
    size = Map.fetch!(@operand_bytes, mode) + 1
    byte_addresses = for offset <- 0..(size - 1), do: address + offset &&& 0xFFFF

    bytes =
      Enum.map(byte_addresses, fn byte_address ->
        if MMC5Profile.rom_address?(signature, byte_address),
          do: read8(prg, signature, byte_address),
          else: nil
      end)

    {successors, terminator, dynamic_exit} =
      if Enum.any?(bytes, &is_nil/1),
        do: {[], :dynamic, :operand_outside_rom},
        else: successors(operation, mode, address, size, bytes)

    %{
      address: address,
      physical_offset: offset(signature, address, byte_size(prg)),
      opcode: opcode,
      operation: operation,
      mode: mode,
      base_cycles: cycles,
      size: size,
      bytes: bytes,
      successors: successors,
      terminator: terminator,
      dynamic_exit: dynamic_exit
    }
  end

  defp successors(operation, :rel, address, size, [_opcode, displacement])
       when operation in @branches do
    next = address + size &&& 0xFFFF
    signed = if displacement < 0x80, do: displacement, else: displacement - 0x100
    target = next + signed &&& 0xFFFF
    {[%{kind: :branch_taken, address: target}, %{kind: :branch_not_taken, address: next}],
     :branch, nil}
  end

  defp successors(:JMP, :abs, _address, _size, [_opcode, low, high]),
    do: {[%{kind: :jump, address: low ||| high <<< 8}], :jump, nil}

  defp successors(:JMP, :ind, _address, _size, _bytes),
    do: {[], :dynamic, :jmp_indirect}

  defp successors(:JSR, :abs, address, size, [_opcode, low, high]) do
    {[%{kind: :call, address: low ||| high <<< 8},
      %{kind: :return, address: address + size &&& 0xFFFF}], :call, nil}
  end

  defp successors(operation, _mode, _address, _size, _bytes)
       when operation in @terminal_operations,
       do: {[], :dynamic, operation |> Atom.to_string() |> String.downcase() |> String.to_atom()}

  defp successors(_operation, _mode, address, size, _bytes),
    do: {[%{kind: :next, address: address + size &&& 0xFFFF}], :none, nil}

  defp block_starts(signature, entries, instructions) do
    edge_starts =
      instructions
      |> Map.values()
      |> Enum.flat_map(fn instruction ->
        if instruction.terminator == :none,
          do: [],
          else: Enum.map(instruction.successors, & &1.address)
      end)

    (entries ++ edge_starts)
    |> Enum.filter(&Map.has_key?(instructions, {signature, &1}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_blocks(signature, starts, instructions) do
    start_set = MapSet.new(starts)

    Map.new(starts, fn start ->
      addresses = follow_block(signature, start, instructions, start_set, [])
      last = Map.fetch!(instructions, {signature, List.last(addresses)})

      {{signature, start},
       %{
         signature: signature,
         start: start,
         addresses: addresses,
         instruction_count: length(addresses),
         base_cycles:
           Enum.sum(Enum.map(addresses, &Map.fetch!(instructions, {signature, &1}).base_cycles)),
         exit: %{terminator: last.terminator, successors: last.successors}
       }}
    end)
  end

  defp follow_block(signature, address, instructions, starts, reversed) do
    instruction = Map.fetch!(instructions, {signature, address})
    reversed = [address | reversed]

    case instruction do
      %{terminator: :none, successors: [%{kind: :next, address: next}]} ->
        if Map.has_key?(instructions, {signature, next}) and not MapSet.member?(starts, next),
          do: follow_block(signature, next, instructions, starts, reversed),
          else: Enum.reverse(reversed)

      _ ->
        Enum.reverse(reversed)
    end
  end

  defp read8(prg, signature, address), do: :binary.at(prg, offset(signature, address, byte_size(prg)))

  defp offset({banks, _ram_windows}, address, size) do
    window = (address - 0x8000) >>> 13
    rem(elem(banks, window) + (address &&& 0x1FFF), size)
  end
end
