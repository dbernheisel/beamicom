defmodule NxNes.BranchlessCPU do
  @moduledoc """
  Ten-operation CPU experiment for measuring table-driven, branchless dispatch.

  This is deliberately separate from the complete NES CPU. It establishes the
  cost and correctness of the proposed execution shape before expanding it.
  `run_journaled/4` keeps RAM out of the instruction loop carry and forwards
  pending writes through a bounded journal before flushing them in order.
  """
  import Nx.Defn
  @journal_capacity 8

  def journal_capacity, do: @journal_capacity

  @adc 1
  @and_op 2
  @bne 3
  @clc 4
  @dex 5
  @inc 6
  @jmp 7
  @lda 8
  @ldx 9
  @sta 10

  @imp 0
  @imm 1
  @zp 2
  @abs 3
  @rel 4

  @definitions [
    {0x65, @adc, @zp, 2, 3},
    {0x29, @and_op, @imm, 2, 2},
    {0xD0, @bne, @rel, 2, 2},
    {0x18, @clc, @imp, 1, 2},
    {0xCA, @dex, @imp, 1, 2},
    {0xE6, @inc, @zp, 2, 5},
    {0x4C, @jmp, @abs, 3, 3},
    {0xA5, @lda, @zp, 2, 3},
    {0xA2, @ldx, @imm, 2, 2},
    {0x85, @sta, @zp, 2, 3}
  ]

  @op_table Enum.reduce(@definitions, List.duplicate(0, 256), fn {byte, op, _, _, _}, table ->
              List.replace_at(table, byte, op)
            end)
  @mode_table Enum.reduce(@definitions, List.duplicate(0, 256), fn {byte, _, mode, _, _}, table ->
                List.replace_at(table, byte, mode)
              end)
  @size_table Enum.reduce(@definitions, List.duplicate(1, 256), fn {byte, _, _, size, _}, table ->
                List.replace_at(table, byte, size)
              end)
  @cycle_table Enum.reduce(@definitions, List.duplicate(0, 256), fn {byte, _, _, _, cycles},
                                                                    table ->
                 List.replace_at(table, byte, cycles)
               end)

  @doc "Registers are `[A, X, Y, SP, P, PC, cycles, reason]` in one s64 vector."
  defn run(registers, ram, rom, limit) do
    {registers, ram, _, _, _} =
      while {registers, ram, count = Nx.tensor(0, type: :s32), rom, limit},
            count < limit and registers[7] == 0 do
        {registers, ram} = step(registers, ram, rom)
        {registers, ram, count + 1, rom, limit}
      end

    {registers, ram}
  end

  defn run_journaled(registers, ram, rom, limit) do
    {registers, ram, _, _, _} =
      while {registers, ram, count = Nx.tensor(0, type: :s32), rom, limit},
            count < limit and registers[7] == 0 do
        keys = Nx.broadcast(Nx.tensor(0, type: :s32), {@journal_capacity})
        values = Nx.broadcast(Nx.tensor(0, type: :u8), {@journal_capacity})

        {registers, keys, values, journal_count, count, _, _, _} =
          while {registers, keys, values, journal_count = Nx.tensor(0, type: :s32), count, ram,
                 rom, limit},
                count < limit and registers[7] == 0 and journal_count < @journal_capacity do
            {registers, keys, values, journal_count} =
              journaled_step(registers, ram, keys, values, journal_count, rom)

            {registers, keys, values, journal_count, count + 1, ram, rom, limit}
          end

        {registers, flush_journal(ram, keys, values, journal_count), count, rom, limit}
      end

    {registers, ram}
  end

  defn step(registers, ram, rom) do
    a = registers[0]
    x = registers[1]
    p = registers[4]
    pc = registers[5]
    opcode = Nx.as_type(rom[band(pc, 0xFFFF)], :s32)
    op = Nx.tensor(@op_table, type: :s32)[opcode]
    mode = Nx.tensor(@mode_table, type: :s32)[opcode]
    size = Nx.tensor(@size_table, type: :s32)[opcode]
    base_cycles = Nx.tensor(@cycle_table, type: :s32)[opcode]
    lo = Nx.as_type(rom[band(pc + 1, 0xFFFF)], :s64)
    hi = Nx.as_type(rom[band(pc + 2, 0xFFFF)], :s64)
    absolute = bor(lo, shl(hi, 8))
    relative = band(pc + 2 + Nx.select(lo >= 128, lo - 256, lo), 0xFFFF)

    address =
      Nx.select(
        mode == @imm,
        band(pc + 1, 0xFFFF),
        Nx.select(mode == @zp, lo, Nx.select(mode == @abs, absolute, relative))
      )

    value =
      Nx.select(
        address < 0x2000,
        Nx.as_type(ram[band(address, 0x07FF)], :s64),
        Nx.as_type(rom[band(address, 0xFFFF)], :s64)
      )

    carry = band(p, 1)
    sum = a + value + carry
    adc = band(sum, 0xFF)
    adc_p = set_zn(p, adc)
    adc_p = set_flag(adc_p, 1, sum > 0xFF)

    adc_p =
      set_flag(adc_p, 0x40, band(band(bitnot(bxor(a, value)), bxor(a, adc)), 0x80) != 0)

    and_value = band(a, value)
    inc_value = band(value + 1, 0xFF)
    dex_value = band(x - 1, 0xFF)

    next_a =
      Nx.select(
        op == @adc,
        adc,
        Nx.select(op == @and_op, and_value, Nx.select(op == @lda, value, a))
      )

    next_x = Nx.select(op == @ldx, value, Nx.select(op == @dex, dex_value, x))

    next_p =
      Nx.select(
        op == @adc,
        adc_p,
        Nx.select(
          op == @and_op or op == @lda,
          set_zn(p, next_a),
          Nx.select(
            op == @ldx or op == @dex,
            set_zn(p, next_x),
            Nx.select(op == @inc, set_zn(p, inc_value), Nx.select(op == @clc, band(p, 0xFE), p))
          )
        )
      )

    sequential_pc = band(pc + size, 0xFFFF)
    branch_taken = op == @bne and band(p, 2) == 0
    next_pc = Nx.select(op == @jmp, absolute, Nx.select(branch_taken, relative, sequential_pc))
    cycles = base_cycles + Nx.as_type(branch_taken, :s64)
    write = op == @sta or op == @inc
    write_index = Nx.select(write, band(address, 0x07FF), 0)
    old = Nx.as_type(ram[write_index], :s64)
    write_value = Nx.select(op == @inc, inc_value, Nx.select(op == @sta, a, old))

    ram =
      Nx.indexed_put(
        ram,
        Nx.reshape(write_index, {1, 1}),
        Nx.reshape(Nx.as_type(write_value, :u8), {1})
      )

    registers =
      Nx.stack([
        next_a,
        next_x,
        registers[2],
        registers[3],
        next_p,
        next_pc,
        registers[6] + cycles,
        Nx.as_type(op == 0, :s64)
      ])

    {registers, ram}
  end

  defn journaled_step(registers, ram, keys, values, journal_count, rom) do
    a = registers[0]
    x = registers[1]
    p = registers[4]
    pc = registers[5]
    opcode = Nx.as_type(rom[band(pc, 0xFFFF)], :s32)
    op = Nx.tensor(@op_table, type: :s32)[opcode]
    mode = Nx.tensor(@mode_table, type: :s32)[opcode]
    size = Nx.tensor(@size_table, type: :s32)[opcode]
    base_cycles = Nx.tensor(@cycle_table, type: :s32)[opcode]
    lo = Nx.as_type(rom[band(pc + 1, 0xFFFF)], :s64)
    hi = Nx.as_type(rom[band(pc + 2, 0xFFFF)], :s64)
    absolute = bor(lo, shl(hi, 8))
    relative = band(pc + 2 + Nx.select(lo >= 128, lo - 256, lo), 0xFFFF)

    address =
      Nx.select(
        mode == @imm,
        band(pc + 1, 0xFFFF),
        Nx.select(mode == @zp, lo, Nx.select(mode == @abs, absolute, relative))
      )

    key = band(address, 0x07FF)
    slots = Nx.iota({@journal_capacity}, type: :s32)
    matching = slots < journal_count and keys == key
    latest = Nx.reduce_max(Nx.select(matching, slots + 1, 0))
    base = Nx.as_type(ram[key], :s64)
    forwarded = Nx.as_type(values[Nx.max(latest - 1, 0)], :s64)

    value =
      Nx.select(
        address < 0x2000,
        Nx.select(latest > 0, forwarded, base),
        Nx.as_type(rom[band(address, 0xFFFF)], :s64)
      )

    carry = band(p, 1)
    sum = a + value + carry
    adc = band(sum, 0xFF)
    adc_p = set_zn(p, adc)
    adc_p = set_flag(adc_p, 1, sum > 0xFF)

    adc_p =
      set_flag(adc_p, 0x40, band(band(bitnot(bxor(a, value)), bxor(a, adc)), 0x80) != 0)

    and_value = band(a, value)
    inc_value = band(value + 1, 0xFF)
    dex_value = band(x - 1, 0xFF)

    next_a =
      Nx.select(
        op == @adc,
        adc,
        Nx.select(op == @and_op, and_value, Nx.select(op == @lda, value, a))
      )

    next_x = Nx.select(op == @ldx, value, Nx.select(op == @dex, dex_value, x))

    next_p =
      Nx.select(
        op == @adc,
        adc_p,
        Nx.select(
          op == @and_op or op == @lda,
          set_zn(p, next_a),
          Nx.select(
            op == @ldx or op == @dex,
            set_zn(p, next_x),
            Nx.select(op == @inc, set_zn(p, inc_value), Nx.select(op == @clc, band(p, 0xFE), p))
          )
        )
      )

    sequential_pc = band(pc + size, 0xFFFF)
    branch_taken = op == @bne and band(p, 2) == 0
    next_pc = Nx.select(op == @jmp, absolute, Nx.select(branch_taken, relative, sequential_pc))
    cycles = base_cycles + Nx.as_type(branch_taken, :s64)
    write = op == @sta or op == @inc
    slot = Nx.select(write, journal_count, 0)
    old_key = keys[slot]
    old_value = values[slot]
    write_value = Nx.select(op == @inc, inc_value, a)

    keys =
      Nx.indexed_put(
        keys,
        Nx.reshape(slot, {1, 1}),
        Nx.reshape(Nx.select(write, Nx.as_type(key, :s32), old_key), {1})
      )

    values =
      Nx.indexed_put(
        values,
        Nx.reshape(slot, {1, 1}),
        Nx.reshape(Nx.select(write, Nx.as_type(write_value, :u8), old_value), {1})
      )

    registers =
      Nx.stack([
        next_a,
        next_x,
        registers[2],
        registers[3],
        next_p,
        next_pc,
        registers[6] + cycles,
        Nx.as_type(op == 0, :s64)
      ])

    {registers, keys, values, journal_count + Nx.as_type(write, :s32)}
  end

  defnp flush_journal(ram, keys, values, journal_count) do
    {ram, _, _, _, _} =
      while {ram, i = Nx.tensor(0, type: :s32), keys, values, journal_count},
            i < journal_count do
        ram =
          Nx.indexed_put(
            ram,
            Nx.reshape(keys[i], {1, 1}),
            Nx.reshape(values[i], {1})
          )

        {ram, i + 1, keys, values, journal_count}
      end

    ram
  end

  defnp set_zn(p, value) do
    p = set_flag(p, 2, band(value, 0xFF) == 0)
    set_flag(p, 0x80, band(value, 0x80) != 0)
  end

  defnp set_flag(p, mask, condition) do
    Nx.select(condition, bor(p, mask), band(p, bxor(mask, 0xFF)))
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(bxor(a, b), do: Nx.bitwise_xor(a, b))
  defnp(bitnot(a), do: Nx.bitwise_not(a))
  defnp(shl(a, b), do: Nx.left_shift(a, b))
end
