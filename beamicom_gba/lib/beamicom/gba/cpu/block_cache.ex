defmodule Beamicom.GBA.CPU.BlockCache do
  @moduledoc false

  import Bitwise

  alias Beamicom.GBA.{Bus, CPU, Cartridge}
  alias Beamicom.GBA.CPU.{ARM, ArmLoop, DecodedBlock, Thumb}
  alias Beamicom.GBA.Memory.Region

  @maximum_block_length 32
  @default_limit 4_096
  @rom_start 0x0800_0000
  @rom_end 0x0E00_0000

  @iwram_start 0x0300_0000
  @iwram_end 0x0400_0000

  @enforce_keys [:arm_blocks, :thumb_blocks, :iwram_arm_blocks, :iwram_thumb_blocks, :limit]
  defstruct @enforce_keys

  def new(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if not is_integer(limit) or limit < 0 do
      raise ArgumentError, "block cache limit must be a non-negative integer"
    end

    %__MODULE__{
      arm_blocks: %{},
      thumb_blocks: %{},
      iwram_arm_blocks: %{},
      iwram_thumb_blocks: %{},
      limit: limit
    }
  end

  def cacheable?(%CPU{run_state: :running} = cpu) do
    address = CPU.register(cpu, 15)
    width = if CPU.thumb?(cpu), do: 2, else: 4

    ((address >= @rom_start and address < @rom_end) or
       (address >= @iwram_start and address < @iwram_end)) and rem(address, width) == 0
  end

  def cacheable?(%CPU{}), do: false

  def fetch(%__MODULE__{} = cache, %CPU{} = cpu, %Cartridge{} = cartridge) do
    mode = if CPU.thumb?(cpu), do: :thumb, else: :arm
    address = CPU.register(cpu, 15)
    blocks = blocks(cache, mode)

    case Map.fetch(blocks, address) do
      {:ok, block} ->
        {block, cache}

      :error ->
        block = decode_block(mode, address, cartridge)
        {block, put_block(cache, mode, address, block)}
    end
  end

  def fetch(%__MODULE__{} = cache, %CPU{} = cpu, %Bus{} = bus) do
    address = CPU.register(cpu, 15)

    if address in @iwram_start..(@iwram_end - 1) do
      fetch_iwram(cache, cpu, bus, address)
    else
      fetch(cache, cpu, bus.cartridge)
    end
  end

  def size(%__MODULE__{} = cache) do
    map_size(cache.arm_blocks) + map_size(cache.thumb_blocks) +
      map_size(cache.iwram_arm_blocks) + map_size(cache.iwram_thumb_blocks)
  end

  defp decode_block(mode, address, cartridge) do
    width = instruction_width(mode)
    length = min(@maximum_block_length, div(@rom_end - address, width))

    instructions =
      0..(length - 1)
      |> Enum.map(fn index -> decode_instruction(mode, cartridge, address + index * width) end)
      |> List.to_tuple()

    %DecodedBlock{mode: mode, start_address: address, instructions: instructions}
  end

  defp decode_iwram_block(mode, address, bus) do
    width = instruction_width(mode)
    length = min(@maximum_block_length, div(@iwram_end - address, width))

    instructions =
      0..(length - 1)
      |> Enum.map(fn index -> decode_iwram_instruction(mode, bus, address + index * width) end)
      |> List.to_tuple()

    %DecodedBlock{
      mode: mode,
      start_address: address,
      instructions: instructions,
      source: :iwram,
      signature: Region.page_signature(bus.iwram, address - @iwram_start, length * width),
      accelerator: ArmLoop.detect(mode, instructions)
    }
  end

  @doc false
  def block_current?(%DecodedBlock{source: :rom}, %Bus{}), do: true

  def block_current?(%DecodedBlock{source: :iwram} = block, %Bus{} = bus) do
    width = instruction_width(block.mode)

    Region.page_signature(
      bus.iwram,
      block.start_address - @iwram_start,
      tuple_size(block.instructions) * width
    ) == block.signature
  end

  defp decode_instruction(:thumb, cartridge, address) do
    instruction = Cartridge.read16(cartridge, address)
    decoded_thumb(instruction)
  end

  defp decode_instruction(:arm, cartridge, address) do
    instruction = Cartridge.read32(cartridge, address)
    decoded_arm(instruction)
  end

  defp decode_iwram_instruction(:thumb, bus, address) do
    instruction = Bus.peek16(bus, address)
    decoded_thumb(instruction)
  end

  defp decode_iwram_instruction(:arm, bus, address) do
    instruction = Bus.peek32(bus, address)
    decoded_arm(instruction)
  end

  defp decoded_thumb(instruction) do
    kind = Thumb.decode_kind(instruction)

    sequential? =
      kind not in [
        :conditional_branch,
        :high_register,
        :push_pop,
        :unconditional_branch,
        :long_branch_suffix
      ]

    memory_access? =
      kind in [
        :immediate_transfer,
        :pc_relative_load,
        :register_transfer,
        :halfword_transfer,
        :stack_relative_transfer,
        :push_pop,
        :multiple_transfer
      ]

    {instruction, kind, sequential?, memory_access?}
  end

  defp decoded_arm(instruction) do
    kind = ARM.decode_kind(instruction)

    sequential? =
      case kind do
        kind when kind in [:branch, :branch_exchange] ->
          false

        :data_processing ->
          opcode = instruction >>> 21 &&& 0xF
          destination = instruction >>> 12 &&& 0xF
          destination != 15 or opcode in 8..11

        :single_transfer ->
          not bit?(instruction, 20) or (instruction >>> 12 &&& 0xF) != 15

        :halfword_transfer ->
          not bit?(instruction, 20) or (instruction >>> 12 &&& 0xF) != 15

        :block_transfer ->
          not (bit?(instruction, 20) and bit?(instruction, 15))

        :multiply ->
          (instruction >>> 16 &&& 0xF) != 15

        :long_multiply ->
          (instruction >>> 16 &&& 0xF) != 15 and (instruction >>> 12 &&& 0xF) != 15

        _other ->
          true
      end

    memory_write? =
      case kind do
        kind when kind in [:single_transfer, :halfword_transfer, :block_transfer] ->
          not bit?(instruction, 20)

        :swap ->
          true

        :software_interrupt ->
          true

        _other ->
          false
      end

    {instruction, kind, sequential?, memory_write?}
  end

  defp instruction_width(:thumb), do: 2
  defp instruction_width(:arm), do: 4

  defp blocks(cache, :thumb), do: cache.thumb_blocks
  defp blocks(cache, :arm), do: cache.arm_blocks

  defp iwram_blocks(cache, :thumb), do: cache.iwram_thumb_blocks
  defp iwram_blocks(cache, :arm), do: cache.iwram_arm_blocks

  defp fetch_iwram(cache, cpu, bus, address) do
    mode = if CPU.thumb?(cpu), do: :thumb, else: :arm
    width = instruction_width(mode)
    byte_length = min(@maximum_block_length * width, @iwram_end - address)
    signature = Region.page_signature(bus.iwram, address - @iwram_start, byte_length)

    case Map.fetch(iwram_blocks(cache, mode), address) do
      {:ok, {^signature, block}} ->
        {block, cache}

      _missing_or_stale ->
        block = decode_iwram_block(mode, address, bus)
        {block, put_iwram_block(cache, mode, address, signature, block)}
    end
  end

  defp put_block(%__MODULE__{limit: limit} = cache, mode, address, block) do
    if size(cache) >= limit do
      cache
    else
      put_available_block(cache, mode, address, block)
    end
  end

  defp put_available_block(cache, :thumb, address, block),
    do: %{cache | thumb_blocks: Map.put(cache.thumb_blocks, address, block)}

  defp put_available_block(cache, :arm, address, block),
    do: %{cache | arm_blocks: Map.put(cache.arm_blocks, address, block)}

  defp put_iwram_block(cache, mode, address, signature, block) do
    blocks = iwram_blocks(cache, mode)

    if Map.has_key?(blocks, address) or size(cache) < cache.limit do
      put_iwram_blocks(cache, mode, Map.put(blocks, address, {signature, block}))
    else
      cache
    end
  end

  defp put_iwram_blocks(cache, :thumb, blocks), do: %{cache | iwram_thumb_blocks: blocks}
  defp put_iwram_blocks(cache, :arm, blocks), do: %{cache | iwram_arm_blocks: blocks}

  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
