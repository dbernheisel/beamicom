defmodule NxNes.Core.Blocks do
  @moduledoc """
  Experimental ROM-specialized straight-line compiler for the NROM resident CPU.
  Immediate, implied and direct internal-RAM instructions are fused. Other
  instructions use CPU.step, including partial blocks at scheduler deadlines.
  ROM bytes and mapping are guarded once per invocation. No compiled code is
  trusted after a cartridge change. This is not an MMC5 mapper or scheduler.
  """
  import Nx.Defn
  alias NxNes.Core.{CPU, Decode}
  alias Beamicom.NES.Cart

  @loads ~w(LDA LDX LDY)
  @stores ~w(STA STX STY)
  @alu ~w(ADC SBC AND ORA EOR CMP CPX CPY BIT INC DEC)
  @implied ~w(CLC SEC CLI SEI CLD SED CLV INX INY DEX DEY TAX TAY TXA TYA TSX TXS NOP)

  def analyze(media, pc, max_instructions \\ 16) do
    with {:ok, cart} <- Cart.parse(media) do
      if cart.mapper != 0 or byte_size(cart.prg_rom) not in [16384, 32768] or
           pc not in 0x8000..0xFFFF or max_instructions not in 1..64 do
        {:error, :unsupported_block_source}
      else
        mask = byte_size(cart.prg_rom) - 1
        instructions = scan(cart.prg_rom, mask, pc, max_instructions, [])

        if instructions == [] do
          {:error, :no_compilable_instructions}
        else
          bytes = Enum.flat_map(instructions, & &1.bytes)
          indices = for i <- 0..(length(bytes) - 1), do: Bitwise.band(pc + i - 0x8000, mask)

          {:ok,
           %{
             entry: pc,
             mask: mask,
             indices: indices,
             bytes: bytes,
             instructions: instructions,
             count: length(instructions),
             cycles: Enum.sum(Enum.map(instructions, & &1.cycles))
           }}
        end
      end
    end
  end

  defp scan(_, _, _, 0, acc), do: Enum.reverse(acc)
  defp scan(_, _, pc, _, acc) when pc > 0xFFFF, do: Enum.reverse(acc)

  defp scan(prg, mask, pc, left, acc) do
    byte = :binary.at(prg, Bitwise.band(pc - 0x8000, mask))
    {op, mode, cycles, _} = Decode.metadata(byte)

    size =
      case mode do
        m when m in ["imp", "acc"] -> 1
        m when m in ["abs", "abx", "aby", "ind"] -> 3
        _ -> 2
      end

    bytes = for i <- 0..(size - 1), do: :binary.at(prg, Bitwise.band(pc + i - 0x8000, mask))

    operand =
      case bytes do
        [_, lo, hi] -> lo + 256 * hi
        [_, lo] -> lo
        [_] -> 0
      end

    supported =
      (op in @implied and mode == "imp") or
        (op in (@loads ++ @alu) and mode == "imm") or
        (op in (@loads ++ @stores ++ @alu) and mode in ["zp", "abs"] and operand < 0x2000) or
        (op == "JMP" and mode == "abs")

    if supported and pc + size <= 0x10000 do
      instruction = %{
        op: op,
        mode: mode,
        operand: operand,
        cycles: cycles,
        bytes: bytes,
        pc: pc,
        next: Bitwise.band(pc + size, 65535)
      }

      if op == "JMP",
        do: Enum.reverse([instruction | acc]),
        else: scan(prg, mask, pc + size, left - 1, [instruction | acc])
    else
      Enum.reverse(acc)
    end
  end

  defn run(s, deadline, limit, opts) do
    block = opts[:block]
    valid = valid_source(s, block)
    s = %{s | reason: Nx.tensor(0, type: :s32)}

    {s, count, hits, _, _, _} =
      while {s, count = Nx.tensor(0, type: :s32), hits = Nx.tensor(0, type: :s32), deadline,
             limit, valid},
            s.reason == 0 and count < limit and s.cycles < deadline do
        if valid and s.pc == block_entry(block) and
             s.cycles + block_cycles(block) <= deadline and
             count + block_count(block) <= limit and
             s.io_read_ready == 0 and s.io_write_ready == 0 do
          {emit(s, block), count + block_count(block), hits + 1, deadline, limit, valid}
        else
          next = CPU.step(s, deadline)
          {next, count + Nx.as_type(next.reason == 0, :s32), hits, deadline, limit, valid}
        end
      end

    reason = Nx.select(s.cycles >= deadline, 1, Nx.select(count >= limit, 5, s.reason))
    {%{s | reason: reason}, count, hits}
  end

  deftransformp(block_entry(b), do: b.entry)
  deftransformp(block_count(b), do: b.count)
  deftransformp(block_cycles(b), do: b.cycles)

  deftransformp valid_source(s, b) do
    Nx.logical_and(
      Nx.equal(s.prg_mask, b.mask),
      Nx.all(Nx.equal(Nx.take(s.prg, Nx.tensor(b.indices)), Nx.tensor(b.bytes, type: :u8)))
    )
  end

  # These are tracing-time Elixir transformations, not runtime host callbacks.
  # Keep known RAM addresses in an SSA map, then emit only their final stores.
  @doc false
  deftransform emit(s, block) do
    {s, writes} =
      Enum.reduce(block.instructions, {s, %{}}, fn i, {s, ram} ->
        addr = Bitwise.band(i.operand, 2047)

        v =
          if i.mode == "imm",
            do: Nx.tensor(i.operand, type: :s32),
            else: Map.get_lazy(ram, addr, fn -> Nx.as_type(Nx.take(s.ram, addr), :s32) end)

        {s, ram} = operation(s, ram, addr, v, i.op)
        pc = if i.op == "JMP", do: i.operand, else: i.next

        {%{
           s
           | pc: Nx.tensor(pc, type: :s32),
             cycles: Nx.add(s.cycles, i.cycles),
             event_cycle: Nx.add(s.cycles, i.cycles - 1),
             opcode: Nx.tensor(hd(i.bytes), type: :s32)
         }, ram}
      end)

    ram =
      Enum.reduce(Enum.sort(writes), s.ram, fn {addr, v}, ram ->
        Nx.put_slice(ram, [addr], Nx.reshape(Nx.as_type(v, :u8), {1}))
      end)

    %{s | ram: ram}
  end

  defp operation(s, ram, addr, v, op) do
    case op do
      "LDA" ->
        {load(s, :a, v), ram}

      "LDX" ->
        {load(s, :x, v), ram}

      "LDY" ->
        {load(s, :y, v), ram}

      "STA" ->
        {s, Map.put(ram, addr, s.a)}

      "STX" ->
        {s, Map.put(ram, addr, s.x)}

      "STY" ->
        {s, Map.put(ram, addr, s.y)}

      "ADC" ->
        {adc(s, v), ram}

      "SBC" ->
        {adc(s, Nx.bitwise_xor(v, 255)), ram}

      "AND" ->
        {load(s, :a, Nx.bitwise_and(s.a, v)), ram}

      "ORA" ->
        {load(s, :a, Nx.bitwise_or(s.a, v)), ram}

      "EOR" ->
        {load(s, :a, Nx.bitwise_xor(s.a, v)), ram}

      op when op in ["CMP", "CPX", "CPY"] ->
        reg = Map.fetch!(s, %{"CMP" => :a, "CPX" => :x, "CPY" => :y}[op])
        {%{s | p: flag(zn(s.p, Nx.subtract(reg, v)), 1, Nx.greater_equal(reg, v))}, ram}

      "BIT" ->
        p = flag(s.p, 2, Nx.equal(Nx.bitwise_and(s.a, v), 0))
        {%{s | p: flag(flag(p, 128, Nx.bitwise_and(v, 128)), 64, Nx.bitwise_and(v, 64))}, ram}

      op when op in ["INC", "DEC"] ->
        v = Nx.bitwise_and(Nx.add(v, if(op == "INC", do: 1, else: -1)), 255)
        {%{s | p: zn(s.p, v)}, Map.put(ram, addr, v)}

      op when op in ["INX", "INY", "DEX", "DEY"] ->
        reg = if op in ["INX", "DEX"], do: :x, else: :y
        {load(s, reg, Nx.add(Map.fetch!(s, reg), if(op in ["INX", "INY"], do: 1, else: -1))), ram}

      op when op in ["TAX", "TAY", "TXA", "TYA", "TSX", "TXS"] ->
        {src, dst} =
          %{
            "TAX" => {:a, :x},
            "TAY" => {:a, :y},
            "TXA" => {:x, :a},
            "TYA" => {:y, :a},
            "TSX" => {:sp, :x},
            "TXS" => {:x, :sp}
          }[op]

        {if(dst == :sp, do: %{s | sp: s.x}, else: load(s, dst, Map.fetch!(s, src))), ram}

      op when op in ["CLC", "SEC", "CLI", "SEI", "CLD", "SED", "CLV"] ->
        {mask, on} =
          %{
            "CLC" => {1, 0},
            "SEC" => {1, 1},
            "CLI" => {4, 0},
            "SEI" => {4, 1},
            "CLD" => {8, 0},
            "SED" => {8, 1},
            "CLV" => {64, 0}
          }[op]

        {%{s | p: flag(s.p, mask, on)}, ram}

      op when op in ["NOP", "JMP"] ->
        {s, ram}
    end
  end

  defp load(s, reg, v), do: Map.merge(s, %{reg => Nx.bitwise_and(v, 255), p: zn(s.p, v)})

  defp zn(p, v),
    do: flag(flag(p, 2, Nx.equal(Nx.bitwise_and(v, 255), 0)), 128, Nx.bitwise_and(v, 128))

  defp flag(p, mask, on),
    do:
      Nx.select(
        Nx.not_equal(on, 0),
        Nx.bitwise_or(p, mask),
        Nx.bitwise_and(p, Bitwise.bxor(mask, 255))
      )

  defp adc(s, v) do
    sum = Nx.add(Nx.add(s.a, v), Nx.bitwise_and(s.p, 1))
    a = Nx.bitwise_and(sum, 255)
    overflow = Nx.bitwise_and(Nx.bitwise_and(Nx.bitwise_xor(s.a, a), Nx.bitwise_xor(v, a)), 128)
    %{s | a: a, p: flag(flag(zn(s.p, a), 1, Nx.greater(sum, 255)), 64, overflow)}
  end
end
