defmodule Beamicom.NES.Recompiler.Discovery do
  @moduledoc """
  Recursive-descent code discovery for mapper-0 PRG ROM.

  Discovery follows only control flow whose target is encoded in ROM. Indirect
  jumps and stack-derived returns are recorded as dynamic exits for the generated
  dispatch layer. The result deliberately retains instruction bytes and edges so
  code generation never has to rediscover instruction boundaries.
  """

  import Bitwise

  alias Beamicom.NES.{CPU, Cart}

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

  @doc "Discover reachable instructions and basic blocks in an NROM cartridge."
  def discover(%Cart{mapper: mapper}) when mapper != 0,
    do: {:error, {:unsupported_mapper, mapper}}

  def discover(%Cart{mapper: 0, prg_rom: prg}) when byte_size(prg) not in [0x4000, 0x8000],
    do: {:error, {:invalid_nrom_prg_size, byte_size(prg)}}

  def discover(%Cart{mapper: 0, prg_rom: prg}) do
    roots = %{
      nmi: read16(prg, 0xFFFA),
      reset: read16(prg, 0xFFFC),
      irq: read16(prg, 0xFFFE)
    }

    queue =
      roots
      |> Map.values()
      |> Enum.filter(&rom_address?/1)
      |> Enum.uniq()
      |> :queue.from_list()

    {instructions, dynamic_exits} = walk(prg, queue, %{}, [])
    starts = block_starts(roots, instructions)
    blocks = build_blocks(starts, instructions)

    {:ok,
     %{
       mapper: 0,
       prg_size: byte_size(prg),
       roots: roots,
       instructions: instructions,
       block_starts: starts,
       blocks: blocks,
       dynamic_exits: Enum.reverse(dynamic_exits),
       instruction_bytes: instruction_byte_count(instructions)
     }}
  end

  @doc "Translate a mapper-0 CPU ROM address to its physical PRG byte offset."
  def prg_offset(%Cart{mapper: 0, prg_rom: prg}, address), do: prg_offset(prg, address)

  def prg_offset(prg, address)
      when is_binary(prg) and byte_size(prg) in [0x4000, 0x8000] and
             address in 0x8000..0xFFFF,
      do: rem(address - 0x8000, byte_size(prg))

  defp walk(prg, queue, instructions, dynamic_exits) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {instructions, dynamic_exits}

      {{:value, address}, queue} ->
        cond do
          not rom_address?(address) or Map.has_key?(instructions, address) ->
            walk(prg, queue, instructions, dynamic_exits)

          true ->
            instruction = decode(prg, address)
            instructions = Map.put(instructions, address, instruction)

            queue =
              Enum.reduce(instruction.successors, queue, fn %{address: successor}, queue ->
                if rom_address?(successor), do: :queue.in(successor, queue), else: queue
              end)

            dynamic_exits =
              case instruction.dynamic_exit do
                nil -> dynamic_exits
                reason -> [%{address: address, reason: reason} | dynamic_exits]
              end

            dynamic_exits =
              Enum.reduce(instruction.successors, dynamic_exits, fn edge, exits ->
                if rom_address?(edge.address),
                  do: exits,
                  else: [%{address: address, reason: {:target_outside_rom, edge}} | exits]
              end)

            walk(prg, queue, instructions, dynamic_exits)
        end
    end
  end

  defp decode(prg, address) do
    opcode = read8(prg, address)
    {operation, mode, cycles} = CPU.opcode_info(opcode)
    size = Map.fetch!(@operand_bytes, mode) + 1
    byte_addresses = for offset <- 0..(size - 1), do: address + offset &&& 0xFFFF

    bytes =
      Enum.map(byte_addresses, fn byte_address ->
        if rom_address?(byte_address), do: read8(prg, byte_address), else: nil
      end)

    {successors, terminator, dynamic_exit} =
      if Enum.any?(bytes, &is_nil/1),
        do: {[], :dynamic, :operand_outside_rom},
        else: successors(operation, mode, address, size, bytes)

    %{
      address: address,
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

    {[
       %{kind: :branch_taken, address: target},
       %{kind: :branch_not_taken, address: next}
     ], :branch, nil}
  end

  defp successors(:JMP, :abs, _address, _size, [_opcode, low, high]),
    do: {[%{kind: :jump, address: low ||| high <<< 8}], :jump, nil}

  defp successors(:JMP, :ind, _address, _size, _bytes),
    do: {[], :dynamic, :jmp_indirect}

  defp successors(:JSR, :abs, address, size, [_opcode, low, high]) do
    {[
       %{kind: :call, address: low ||| high <<< 8},
       %{kind: :return, address: address + size &&& 0xFFFF}
     ], :call, nil}
  end

  defp successors(operation, _mode, _address, _size, _bytes)
       when operation in @terminal_operations,
       do: {[], :dynamic, operation |> Atom.to_string() |> String.downcase() |> String.to_atom()}

  defp successors(_operation, _mode, address, size, _bytes),
    do: {[%{kind: :next, address: address + size &&& 0xFFFF}], :none, nil}

  defp block_starts(roots, instructions) do
    edge_starts =
      instructions
      |> Map.values()
      |> Enum.flat_map(fn instruction ->
        case instruction.terminator do
          :none -> []
          _ -> Enum.map(instruction.successors, & &1.address)
        end
      end)

    (Map.values(roots) ++ edge_starts)
    |> Enum.filter(&Map.has_key?(instructions, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_blocks(starts, instructions) do
    start_set = MapSet.new(starts)

    Map.new(starts, fn start ->
      addresses = follow_block(start, instructions, start_set, [])
      last = Map.fetch!(instructions, List.last(addresses))

      {start,
       %{
         start: start,
         addresses: addresses,
         instruction_count: length(addresses),
         base_cycles: Enum.sum(Enum.map(addresses, &Map.fetch!(instructions, &1).base_cycles)),
         exit: %{terminator: last.terminator, successors: last.successors}
       }}
    end)
  end

  defp follow_block(address, instructions, starts, reversed) do
    instruction = Map.fetch!(instructions, address)
    reversed = [address | reversed]

    case instruction do
      %{terminator: :none, successors: [%{kind: :next, address: next}]} ->
        if Map.has_key?(instructions, next) and not MapSet.member?(starts, next),
          do: follow_block(next, instructions, starts, reversed),
          else: Enum.reverse(reversed)

      _ ->
        Enum.reverse(reversed)
    end
  end

  defp instruction_byte_count(instructions) do
    instructions
    |> Map.values()
    |> Enum.flat_map(fn instruction ->
      for offset <- 0..(instruction.size - 1), do: instruction.address + offset &&& 0xFFFF
    end)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp read16(prg, address), do: read8(prg, address) ||| read8(prg, address + 1) <<< 8
  defp read8(prg, address), do: :binary.at(prg, prg_offset(prg, address))
  defp rom_address?(address), do: address in 0x8000..0xFFFF
end
