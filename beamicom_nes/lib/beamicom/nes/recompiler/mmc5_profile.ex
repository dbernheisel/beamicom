defmodule Beamicom.NES.Recompiler.MMC5Profile do
  @moduledoc """
  Interpreter-guided collection of MMC5 PRG mappings and dynamic entry points.

  MMC5 has too many possible PRG-register combinations to compile exhaustively.
  A release build can instead run the interpreter over a representative input,
  then recursively discover code under every observed ROM mapping. Unseen bank
  mappings and executable PRG-RAM remain interpreter fallbacks.
  """

  import Bitwise

  alias Beamicom.NES.{Bus, Console, CPU}

  @type signature :: {{non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
                      non_neg_integer()}

  @doc "Collect mapping signatures, dynamic roots, and instruction hit counts."
  def capture(%Console{bus: %{mapper: 5}} = console, instruction_limit)
      when is_integer(instruction_limit) and instruction_limit > 0 do
    do_capture(console, instruction_limit, nil, %{
      mapper: 5,
      roots: %{},
      hits: %{},
      signatures: MapSet.new(),
      mapping_changes: 0,
      interpreted_instructions: 0
    })
  end

  def capture(%Console{bus: %{mapper: mapper}}, _instruction_limit),
    do: {:error, {:unsupported_mapper, mapper}}

  @doc "The ROM-code identity used by generated MMC5 dispatch clauses."
  def signature(%{prg_banks: banks, mapper_state: %{prg_ram_windows: mask}}),
    do: {banks, mask}

  @doc "Whether `address` resolves to PRG-ROM under `signature`."
  def rom_address?({_banks, ram_windows}, address) when address in 0x8000..0xFFFF do
    window = (address - 0x8000) >>> 13
    (ram_windows &&& 1 <<< window) == 0
  end

  def rom_address?(_signature, _address), do: false

  defp do_capture(console, 0, _previous, profile), do: {:ok, profile, console}

  defp do_capture(%Console{} = console, remaining, previous, profile) do
    signature = signature(console.bus)
    pc = console.cpu.pc
    rom? = rom_address?(signature, pc)

    size =
      if rom? do
        opcode = Bus.peek(console.bus, pc)
        {_operation, mode, _cycles} = CPU.opcode_info(opcode)
        operand_bytes(mode) + 1
      else
        1
      end

    root? =
      rom? and
        (previous == nil or previous.signature != signature or
           previous.next_pc != pc)

    roots =
      if root?,
        do: Map.update(profile.roots, signature, MapSet.new([pc]), &MapSet.put(&1, pc)),
        else: profile.roots

    hits =
      if rom?,
        do: Map.update(profile.hits, {signature, pc}, 1, &(&1 + 1)),
        else: profile.hits

    profile = %{
      profile
      | roots: roots,
        hits: hits,
        signatures: MapSet.put(profile.signatures, signature),
        mapping_changes:
          profile.mapping_changes +
            if(previous != nil and previous.signature != signature, do: 1, else: 0),
        interpreted_instructions: profile.interpreted_instructions + 1
    }

    next = Console.step(console)
    previous = %{signature: signature, next_pc: pc + size &&& 0xFFFF}
    do_capture(next, remaining - 1, previous, profile)
  end

  defp operand_bytes(mode) when mode in [:imp, :acc], do: 0
  defp operand_bytes(mode) when mode in [:imm, :zp, :zpx, :zpy, :rel, :izx, :izy], do: 1
  defp operand_bytes(mode) when mode in [:abs, :abx, :aby, :ind], do: 2
end
