defmodule Beamicom.NES.Recompiler.Generator do
  @moduledoc """
  Generates one hash-named BEAM module for a mapper-0 or profiled MMC5 PRG image.

  Common opcode/addressing families expand directly into each generated block.
  Unsupported static instructions deliberately execute one `CPU.step/2` as the
  interpreter fallback, under the same differential oracle as block dispatch.
  """

  import Bitwise

  alias Beamicom.NES.Cart
  alias Beamicom.NES.{Console}
  alias Beamicom.NES.Recompiler.{Discovery, MMC5Discovery, MMC5Profile, Program}

  @doc "Parse, discover, and compile mapper-0 media already held in memory."
  def compile_media(media) when is_binary(media) do
    with {:ok, cart} <- Cart.parse(media) do
      compile(cart)
    end
  end

  @doc "Profile and compile mapper-5 media; mapper-0 media ignores the profile options."
  def compile_media(media, options) when is_binary(media) and is_list(options) do
    with {:ok, cart} <- Cart.parse(media) do
      case cart.mapper do
        0 ->
          compile(cart)

        5 ->
          limit = Keyword.get(options, :profile_instructions, 250_000)

          with {:ok, profile, _console} <-
                 media |> Console.load_binary() |> MMC5Profile.capture(limit) do
            compile(cart, profile)
          end

        mapper ->
          {:error, {:unsupported_mapper, mapper}}
      end
    end
  end

  @doc "Discover a mapper-0 cart and load its hash-named generated BEAM module."
  def compile(%Cart{} = cart) do
    with {:ok, discovery} <- Discovery.discover(cart) do
      hash = :crypto.hash(:sha256, cart.prg_rom)
      module = module_name(hash)

      with :ok <- ensure_module(module, hash, discovery) do
        {:ok,
         %Program{
           module: module,
           rom_hash: hash,
           discovery: discovery,
           stats: :atomics.new(4, signed: false)
         }}
      end
    end
  end

  @doc "Compile profiled MMC5 mappings into the ROM's generated module."
  def compile(%Cart{mapper: 5} = cart, %{mapper: 5} = profile) do
    with {:ok, discovery} <- MMC5Discovery.discover(cart, profile) do
      hash = :crypto.hash(:sha256, cart.prg_rom)
      module = module_name(hash)

      with :ok <- ensure_module(module, hash, discovery) do
        {:ok,
         %Program{
           module: module,
           rom_hash: hash,
           discovery: discovery,
           stats: :atomics.new(4, signed: false)
         }}
      end
    end
  end

  @doc "The deterministic generated module name for a full SHA-256 PRG hash."
  def module_name(<<_::binary-size(32)>> = hash) do
    suffix = Base.encode16(hash, case: :upper)
    Module.concat(Beamicom.NES.Recompiled, "ROM_#{suffix}")
  end

  defp ensure_module(module, hash, discovery) do
    if Code.ensure_loaded?(module) do
      if module.rom_hash() == hash,
        do: :ok,
        else: {:error, {:module_hash_collision, module}}
    else
      quoted = module_body(hash, discovery)

      case Module.create(module, quoted, Macro.Env.location(__ENV__)) do
        {:module, ^module, _binary, _term} -> :ok
        other -> {:error, {:module_create_failed, other}}
      end
    end
  end

  defp module_body(hash, discovery) do
    case discovery.mapper do
      0 -> mapper0_module_body(hash, discovery)
      5 -> mmc5_module_body(hash, discovery)
    end
  end

  defp mapper0_module_body(hash, discovery) do
    blocks = discovery.blocks |> Map.values() |> Enum.sort_by(& &1.start)
    starts = Enum.map(blocks, & &1.start)

    block_definitions =
      Enum.map(blocks, fn block ->
        name = block_name(block.start)

        instructions =
          Enum.map(block.addresses, fn address ->
            instruction = Map.fetch!(discovery.instructions, address)

            {address, instruction.operation, instruction.mode, instruction.base_cycles,
             static_operand(instruction.bytes)}
          end)

        body = emitted_block_body(instructions, nil)

        quote do
          @doc false
          def unquote(name)(a, x, y, sp, p, cycles, ram, context) do
            {var!(cpu), var!(bus)} = Runtime.enter(a, x, y, sp, p, cycles, ram, context)
            var!(frame) = Runtime.frame_marker(var!(bus))
            unquote(body)
          end
        end
      end)

    dispatch_definitions =
      Enum.map(blocks, fn block ->
        name = block_name(block.start)
        address = block.start

        quote do
          def dispatch(%Console{cpu: %CPU{pc: unquote(address)} = cpu, bus: bus}) do
            unquote(name)(cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p, cpu.cycles, bus.ram, {cpu, bus})
          end
        end
      end)

    quote do
      @moduledoc false

      alias Beamicom.NES.{Console, CPU}
      alias Beamicom.NES.Recompiler.{Runtime, Semantics}
      require Semantics

      def rom_hash, do: unquote(hash)
      def block_starts, do: unquote(starts)

      def known_block?(address) when address in unquote(starts), do: true
      def known_block?(_address), do: false
      def known_console?(%Console{cpu: %CPU{pc: address}}), do: known_block?(address)

      unquote_splicing(block_definitions)
      unquote_splicing(dispatch_definitions)

      def dispatch(%Console{} = console), do: Runtime.fallback(console)
    end
  end

  defp mmc5_module_body(hash, discovery) do
    blocks = discovery.blocks |> Map.values() |> Enum.sort_by(&{&1.signature, &1.start})

    indexed = Enum.with_index(blocks)

    block_definitions =
      Enum.map(indexed, fn {block, index} ->
        name = mmc5_block_name(index, block.start)

        instructions =
          Enum.map(block.addresses, fn address ->
            instruction = Map.fetch!(discovery.instructions, {block.signature, address})

            {address, instruction.operation, instruction.mode, instruction.base_cycles,
             static_operand(instruction.bytes),
             mapping_write?(instruction.operation, instruction.mode)}
          end)

        body = emitted_block_body(instructions, block.signature)

        quote do
          @doc false
          def unquote(name)(a, x, y, sp, p, cycles, ram, context) do
            {var!(cpu), var!(bus)} = Runtime.enter(a, x, y, sp, p, cycles, ram, context)
            var!(frame) = Runtime.frame_marker(var!(bus))
            unquote(body)
          end
        end
      end)

    dispatch_definitions =
      Enum.map(indexed, fn {block, index} ->
        name = mmc5_block_name(index, block.start)
        address = block.start
        {banks, ram_windows} = block.signature

        quote do
          def dispatch(%Console{
                cpu: %CPU{pc: unquote(address)} = cpu,
                bus:
                  %{
                    mapper: 5,
                    prg_banks: unquote(Macro.escape(banks)),
                    mapper_state: %{prg_ram_windows: unquote(ram_windows)}
                  } = bus
              }) do
            unquote(name)(cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p, cpu.cycles, bus.ram, {cpu, bus})
          end
        end
      end)

    known_definitions =
      Enum.map(blocks, fn block ->
        address = block.start
        {banks, ram_windows} = block.signature

        quote do
          def known_console?(%Console{
                cpu: %CPU{pc: unquote(address)},
                bus: %{
                  mapper: 5,
                  prg_banks: unquote(Macro.escape(banks)),
                  mapper_state: %{prg_ram_windows: unquote(ram_windows)}
                }
              }),
              do: true
        end
      end)

    starts = Enum.map(blocks, &{&1.signature, &1.start})

    quote do
      @moduledoc false

      alias Beamicom.NES.{Console, CPU}
      alias Beamicom.NES.Recompiler.{Runtime, Semantics}
      require Semantics

      def rom_hash, do: unquote(hash)
      def block_starts, do: unquote(Macro.escape(starts))
      def known_block?(_address), do: false

      unquote_splicing(block_definitions)
      unquote_splicing(known_definitions)
      def known_console?(%Console{}), do: false
      unquote_splicing(dispatch_definitions)
      def dispatch(%Console{} = console), do: Runtime.fallback(console)
    end
  end

  defp block_name(address),
    do:
      String.to_atom("block_" <> (address |> Integer.to_string(16) |> String.pad_leading(4, "0")))

  defp mmc5_block_name(index, address) do
    suffix = address |> Integer.to_string(16) |> String.pad_leading(4, "0")
    String.to_atom("block_m5_#{index}_#{suffix}")
  end

  # Only an opcode that writes through Bus can change an MMC5 PRG register. The
  # generated runtime checks the mapping after these operations instead of
  # rebuilding/comparing the four-window signature after every ALU or load.
  defp mapping_write?(operation, mode) do
    mode not in [:imp, :acc, :imm, :rel] and
      operation in [
        :STA,
        :STX,
        :STY,
        :SAX,
        :AHX,
        :SHX,
        :SHY,
        :TAS,
        :ASL,
        :LSR,
        :ROL,
        :ROR,
        :INC,
        :DEC,
        :DCP,
        :ISC,
        :SLO,
        :RLA,
        :SRE,
        :RRA
      ]
  end

  defp emitted_block_body(instructions, signature),
    do: emitted_instruction_chain(instructions, signature, 0)

  defp emitted_instruction_chain([], _signature, count) do
    quote do
      {%Console{cpu: var!(cpu), bus: var!(bus)}, unquote(count)}
    end
  end

  defp emitted_instruction_chain(
         [{address, operation, mode, base_cycles, operand} | rest],
         nil,
         count
       ) do
    next = emitted_instruction_chain(rest, nil, count + 1)

    quote do
      if var!(cpu).pc == unquote(address) do
        {var!(cpu), var!(bus)} =
          Semantics.step(
            var!(cpu),
            var!(bus),
            unquote(operation),
            unquote(mode),
            unquote(base_cycles),
            unquote(operand)
          )

        if Runtime.same_frame?(var!(bus), var!(frame)) do
          unquote(next)
        else
          {%Console{cpu: var!(cpu), bus: var!(bus)}, unquote(count + 1)}
        end
      else
        {%Console{cpu: var!(cpu), bus: var!(bus)}, unquote(count)}
      end
    end
  end

  defp emitted_instruction_chain(
         [{address, operation, mode, base_cycles, operand, mapping_write?} | rest],
         signature,
         count
       ) do
    next = emitted_instruction_chain(rest, signature, count + 1)

    mapping_guard =
      if mapping_write?,
        do: quote(do: Runtime.same_mapping?(var!(bus), unquote(Macro.escape(signature)))),
        else: true

    quote do
      if var!(cpu).pc == unquote(address) do
        {var!(cpu), var!(bus)} =
          Semantics.step(
            var!(cpu),
            var!(bus),
            unquote(operation),
            unquote(mode),
            unquote(base_cycles),
            unquote(operand)
          )

        if Runtime.same_frame?(var!(bus), var!(frame)) and unquote(mapping_guard) do
          unquote(next)
        else
          {%Console{cpu: var!(cpu), bus: var!(bus)}, unquote(count + 1)}
        end
      else
        {%Console{cpu: var!(cpu), bus: var!(bus)}, unquote(count)}
      end
    end
  end

  defp static_operand([_opcode]), do: nil
  defp static_operand([_opcode, low]), do: low
  defp static_operand([_opcode, low, high]), do: low ||| high <<< 8
end
