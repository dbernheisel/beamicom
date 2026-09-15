defmodule Beamicom.NES.Recompiler.Generator do
  @moduledoc """
  Generates one BEAM module for a mapper-0 PRG image.

  This first correctness checkpoint emits the final block/dispatch ABI while
  delegating instruction semantics to the interpreter oracle. Opcode families
  can then be replaced behind the same ABI under differential tests.
  """

  alias Beamicom.NES.Cart
  alias Beamicom.NES.Recompiler.{Discovery, Program}

  @doc "Parse, discover, and compile mapper-0 media already held in memory."
  def compile_media(media) when is_binary(media) do
    with {:ok, cart} <- Cart.parse(media) do
      compile(cart)
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
    blocks = discovery.blocks |> Map.values() |> Enum.sort_by(& &1.start)
    starts = Enum.map(blocks, & &1.start)

    block_definitions =
      Enum.map(blocks, fn block ->
        name = block_name(block.start)

        instructions =
          Enum.map(block.addresses, fn address ->
            instruction = Map.fetch!(discovery.instructions, address)

            {address, instruction.operation, instruction.mode, instruction.base_cycles}
          end)

        quote do
          @doc false
          def unquote(name)(a, x, y, sp, p, cycles, ram, context) do
            Runtime.run_block(
              a,
              x,
              y,
              sp,
              p,
              cycles,
              ram,
              context,
              unquote(Macro.escape(instructions))
            )
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
      alias Beamicom.NES.Recompiler.Runtime

      def rom_hash, do: unquote(hash)
      def block_starts, do: unquote(starts)

      def known_block?(address) when address in unquote(starts), do: true
      def known_block?(_address), do: false

      unquote_splicing(block_definitions)
      unquote_splicing(dispatch_definitions)

      def dispatch(%Console{} = console), do: Runtime.fallback(console)
    end
  end

  defp block_name(address),
    do:
      String.to_atom("block_" <> (address |> Integer.to_string(16) |> String.pad_leading(4, "0")))
end
