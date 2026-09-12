defmodule NxNes.Core.CPU do
  @moduledoc "ROM-driven resident 2A03 interpreter with explicit device/deadline barriers."
  import Nx.Defn
  import NxNes.Core.Decode, only: [op: 1, mode: 1]
  alias NxNes.Core.{Bus, Decode}

  @handlers [
    37,
    45,
    44,
    12,
    46,
    41,
    29,
    30,
    32,
    39,
    34,
    31,
    33,
    57,
    35,
    36,
    22,
    26,
    24,
    28,
    15,
    16,
    17,
    40,
    40,
    20,
    21,
    14,
    40,
    18,
    19,
    40,
    53,
    54,
    42,
    0,
    1,
    2,
    41,
    42,
    58,
    13,
    49,
    50,
    51,
    52,
    41,
    41,
    41,
    41,
    56,
    55,
    43,
    38,
    47,
    23,
    27,
    25,
    48,
    48,
    41,
    41,
    3,
    4,
    5,
    6,
    7,
    10,
    8,
    11,
    9,
    58
  ]

  defn run(s, deadline, limit) do
    s = %{s | reason: Nx.tensor(0, type: :s32)}

    {s, count, _, _} =
      while {s, count = Nx.tensor(0, type: :s32), deadline, limit},
            s.reason == 0 and count < limit and s.cycles < deadline and journal_room(s) do
        next = step_branchless(s, deadline)
        {next, count + Nx.as_type(next.reason == 0, :s32), deadline, limit}
      end

    reason = Nx.select(s.cycles >= deadline, 1, Nx.select(count >= limit, 5, s.reason))
    {%{s | reason: reason}, count}
  end

  defn step_branchless(original, deadline) do
    original = %{original | reason: Nx.tensor(0, type: :s32)}
    byte = Bus.peek(original, original.pc)
    d = Decode.fetch(byte)
    operation = d[0]
    addressing = d[1]
    {addr, crossed, s} = resolve_branchless(original, addressing)
    cost = d[2] + crossed * d[3]
    s = %{s | opcode: byte, event_cycle: original.cycles + Nx.as_type(cost - 1, :s64)}
    {s, extra} = execute_branchless(s, operation, addressing, addr)
    s = %{s | cycles: s.cycles + Nx.as_type(cost + extra, :s64)}
    s = if operation == op(:UNSUPPORTED), do: %{s | reason: Nx.tensor(4, type: :s32)}, else: s

    s =
      if original.pc >= 0x2000 and original.pc < 0x6000,
        do: %{s | reason: Nx.tensor(6, type: :s32), event_addr: original.pc},
        else: s

    s =
      cond do
        s.cycles > deadline and s.reason < 4 ->
          %{original | reason: Nx.tensor(1, type: :s32), event_cycle: s.cycles, opcode: byte}

        s.reason != 0 ->
          %{
            original
            | reason: s.reason,
              event_addr: s.event_addr,
              event_value: s.event_value,
              event_cycle: s.event_cycle,
              opcode: byte
          }

        true ->
          %{s | io_read_ready: Nx.tensor(0, type: :s32), io_write_ready: Nx.tensor(0, type: :s32)}
      end

    commit_writes(s)
  end

  defn trace(s, limit) do
    s = %{s | reason: Nx.tensor(0, type: :s32)}

    {s, rows, count, _} =
      while {s, rows = Nx.broadcast(Nx.tensor(0, type: :s64), {1024, 7}),
             count = Nx.tensor(0, type: :s32), limit},
            count < limit and count < 1024 and s.reason == 0 do
        row =
          Nx.stack([
            Nx.as_type(s.pc, :s64),
            Nx.as_type(s.a, :s64),
            Nx.as_type(s.x, :s64),
            Nx.as_type(s.y, :s64),
            Nx.as_type(s.p, :s64),
            Nx.as_type(s.sp, :s64),
            s.cycles
          ])

        rows = Nx.put_slice(rows, [count, 0], Nx.reshape(row, {1, 7}))
        s = step(s, Nx.tensor(0x1000000000000000, type: :s64))
        {s, rows, count + Nx.as_type(s.reason == 0, :s32), limit}
      end

    {s, rows, count}
  end

  defn step(original, deadline) do
    original = %{original | reason: Nx.tensor(0, type: :s32)}
    byte = Bus.peek(original, original.pc)
    d = Decode.fetch(byte)
    operation = d[0]
    addressing = d[1]
    {addr, crossed, s} = resolve(original, addressing)
    cost = d[2] + crossed * d[3]
    s = %{s | opcode: byte, event_cycle: original.cycles + Nx.as_type(cost - 1, :s64)}
    {s, extra} = execute(s, operation, addressing, addr)
    s = %{s | cycles: s.cycles + Nx.as_type(cost + extra, :s64)}
    s = if operation == op(:UNSUPPORTED), do: %{s | reason: Nx.tensor(4, type: :s32)}, else: s

    s =
      if original.pc >= 0x2000 and original.pc < 0x6000,
        do: %{s | reason: Nx.tensor(6, type: :s32), event_addr: original.pc},
        else: s

    s =
      cond do
        s.cycles > deadline and s.reason < 4 ->
          %{original | reason: Nx.tensor(1, type: :s32), event_cycle: s.cycles, opcode: byte}

        s.reason != 0 ->
          %{
            original
            | reason: s.reason,
              event_addr: s.event_addr,
              event_value: s.event_value,
              event_cycle: s.event_cycle,
              opcode: byte
          }

        true ->
          %{s | io_read_ready: Nx.tensor(0, type: :s32), io_write_ready: Nx.tensor(0, type: :s32)}
      end

    commit_writes(s)
  end

  deftransformp commit_writes(s) do
    if Map.has_key?(s, :write_count), do: NxNes.Machine.Memory.commit(s), else: s
  end

  deftransformp journal_room(s) do
    if Map.has_key?(s, :journal_count), do: NxNes.Machine.Memory.journal_room(s), else: true
  end

  # kind: 1=NMI, 2=IRQ. Called at a scheduler-selected instruction boundary.
  defn interrupt(s, kind, deadline) do
    original = s
    s = %{s | reason: Nx.tensor(0, type: :s32)}

    if kind == 1 or (kind == 2 and band(s.p, 4) == 0) do
      s = push(s, shr(s.pc, 8))
      s = push(s, band(s.pc, 255))
      s = push(s, bor(band(s.p, 239), 32))
      vector = Nx.select(kind == 1, 0xFFFA, 0xFFFE)
      s = %{s | p: bor(s.p, 4), pc: word(s, vector), cycles: s.cycles + 7}

      if s.cycles > deadline,
        do: %{original | reason: Nx.tensor(1, type: :s32), event_cycle: s.cycles},
        else: s
    else
      s
    end
  end

  defn resolve(s, m) do
    pc = band(s.pc + 1, 65535)
    lo = Bus.peek(s, pc)
    absolute = bor(lo, shl(Bus.peek(s, band(pc + 1, 65535)), 8))

    {addr, nextpc, crossed} =
      cond do
        m == mode(:imp) or m == mode(:acc) ->
          {Nx.tensor(0, type: :s32), pc, Nx.tensor(0, type: :s32)}

        m == mode(:imm) ->
          {pc, band(pc + 1, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:zp) ->
          {lo, band(pc + 1, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:zpx) ->
          {band(lo + s.x, 255), band(pc + 1, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:zpy) ->
          {band(lo + s.y, 255), band(pc + 1, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:abs) ->
          {absolute, band(pc + 2, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:abx) or m == mode(:aby) ->
          a = band(absolute + Nx.select(m == mode(:abx), s.x, s.y), 65535)
          {a, band(pc + 2, 65535), cross(absolute, a)}

        m == mode(:ind) ->
          a =
            bor(
              Bus.peek(s, absolute),
              shl(Bus.peek(s, bor(band(absolute, 65280), band(absolute + 1, 255))), 8)
            )

          {a, band(pc + 2, 65535), Nx.tensor(0, type: :s32)}

        m == mode(:izx) ->
          z = band(lo + s.x, 255)

          {bor(Bus.peek(s, z), shl(Bus.peek(s, band(z + 1, 255)), 8)), band(pc + 1, 65535),
           Nx.tensor(0, type: :s32)}

        m == mode(:izy) ->
          base = bor(Bus.peek(s, lo), shl(Bus.peek(s, band(lo + 1, 255)), 8))
          a = band(base + s.y, 65535)
          {a, band(pc + 1, 65535), cross(base, a)}

        true ->
          nextpc = band(pc + 1, 65535)

          {band(nextpc + Nx.select(lo >= 128, lo - 256, lo), 65535), nextpc,
           Nx.tensor(0, type: :s32)}
      end

    {addr, crossed, %{s | pc: nextpc}}
  end

  defn resolve_branchless(s, m) do
    pc = band(s.pc + 1, 65535)
    lo = Bus.peek(s, pc)
    next1 = band(pc + 1, 65535)
    next2 = band(pc + 2, 65535)
    absolute = bor(lo, shl(Bus.peek(s, next1), 8))
    ab_index = Nx.select(m == mode(:abx), s.x, s.y)
    ab_addr = band(absolute + ab_index, 65535)

    indirect =
      bor(
        Bus.peek(s, absolute),
        shl(Bus.peek(s, bor(band(absolute, 65280), band(absolute + 1, 255))), 8)
      )

    izx_base = band(lo + s.x, 255)
    izx = bor(Bus.peek(s, izx_base), shl(Bus.peek(s, band(izx_base + 1, 255)), 8))
    izy_base = bor(Bus.peek(s, lo), shl(Bus.peek(s, band(lo + 1, 255)), 8))
    izy = band(izy_base + s.y, 65535)
    relative = band(next1 + Nx.select(lo >= 128, lo - 256, lo), 65535)

    addr = Nx.tensor(0, type: :s32)
    addr = Nx.select(m == mode(:imm), pc, addr)
    addr = Nx.select(m == mode(:zp), lo, addr)
    addr = Nx.select(m == mode(:zpx), band(lo + s.x, 255), addr)
    addr = Nx.select(m == mode(:zpy), band(lo + s.y, 255), addr)
    addr = Nx.select(m == mode(:abs), absolute, addr)
    addr = Nx.select(m == mode(:abx) or m == mode(:aby), ab_addr, addr)
    addr = Nx.select(m == mode(:ind), indirect, addr)
    addr = Nx.select(m == mode(:izx), izx, addr)
    addr = Nx.select(m == mode(:izy), izy, addr)
    addr = Nx.select(m == mode(:rel), relative, addr)

    nextpc =
      Nx.select(
        m == mode(:abs) or m == mode(:abx) or m == mode(:aby) or m == mode(:ind),
        next2,
        Nx.select(m == mode(:imp) or m == mode(:acc), pc, next1)
      )

    crossed =
      Nx.select(
        m == mode(:abx) or m == mode(:aby),
        cross(absolute, ab_addr),
        Nx.select(m == mode(:izy), cross(izy_base, izy), 0)
      )

    {addr, crossed, %{s | pc: nextpc}}
  end

  defn reads_operand(o, m) do
    o == op(:LDA) or o == op(:LDX) or o == op(:LDY) or o == op(:AND) or o == op(:ORA) or
      o == op(:EOR) or o == op(:BIT) or
      o == op(:ADC) or o == op(:SBC) or o == op(:CMP) or o == op(:CPX) or o == op(:CPY) or
      o == op(:INC) or o == op(:DEC) or
      o == op(:LAX) or o == op(:DCP) or o == op(:ISB) or o == op(:SLO) or o == op(:RLA) or
      o == op(:SRE) or o == op(:RRA) or
      o == op(:ANC) or o == op(:ALR) or o == op(:ARR) or o == op(:LXA) or o == op(:SBX) or
      ((o == op(:ASL) or o == op(:LSR) or o == op(:ROL) or o == op(:ROR)) and m != mode(:acc))
  end

  # All arithmetic candidates are evaluated from the same input state and the
  # decoded handler selects the committed register/write results. This keeps the
  # hot CPU batch out of the large data-dependent opcode conditional tree.
  defn execute_branchless(s, o, m, addr) do
    reads = reads_operand(o, m)
    {v, s} = if reads, do: Bus.read(s, addr), else: {s.a, s}
    h = Nx.take(Nx.tensor(@handlers, type: :s32), o)
    a = s.a
    x = s.x
    y = s.y
    sp = s.sp
    p = s.p
    pc = s.pc

    sum = a + v + band(p, 1)
    adc_a = band(sum, 255)

    adc_p =
      set(
        set(zn(p, adc_a), 1, sum > 255),
        64,
        band(band(bxor(a, adc_a), bxor(v, adc_a)), 128) != 0
      )

    difference = a + bxor(v, 255) + band(p, 1)
    sbc_a = band(difference, 255)

    sbc_p =
      set(
        set(zn(p, sbc_a), 1, difference > 255),
        64,
        band(band(bxor(a, sbc_a), bxor(bxor(v, 255), sbc_a)), 128) != 0
      )

    rmw_v = band(v + Nx.select(o == op(:INC) or o == op(:ISB), 1, -1), 255)
    rmw_p = Nx.select(o == op(:DCP), compare_p(p, a, rmw_v), zn(p, rmw_v))

    rmw_a = Nx.select(o == op(:ISB), band(a + bxor(rmw_v, 255) + band(p, 1), 255), a)
    rmw_sum = a + bxor(rmw_v, 255) + band(p, 1)

    rmw_adc_p =
      set(
        set(zn(p, rmw_a), 1, rmw_sum > 255),
        64,
        band(band(bxor(a, rmw_a), bxor(bxor(rmw_v, 255), rmw_a)), 128) != 0
      )

    rmw_p = Nx.select(o == op(:ISB), rmw_adc_p, rmw_p)

    asl_v = band(shl(v, 1), 255)
    lsr_v = shr(v, 1)
    rol_v = band(bor(shl(v, 1), band(p, 1)), 255)
    ror_v = bor(shr(v, 1), shl(band(p, 1), 7))
    left = o == op(:ASL) or o == op(:SLO) or o == op(:ROL) or o == op(:RLA)
    rotate = o == op(:ROL) or o == op(:RLA) or o == op(:ROR) or o == op(:RRA)
    shift_v = Nx.select(left, Nx.select(rotate, rol_v, asl_v), Nx.select(rotate, ror_v, lsr_v))
    shift_p = set(p, 1, Nx.select(left, band(v, 128) != 0, band(v, 1) != 0))

    shift_a =
      Nx.select(
        o == op(:SLO),
        bor(a, shift_v),
        Nx.select(o == op(:RLA), band(a, shift_v), Nx.select(o == op(:SRE), bxor(a, shift_v), a))
      )

    rra_sum = a + shift_v + band(shift_p, 1)
    rra_a = band(rra_sum, 255)

    rra_p =
      set(
        set(zn(shift_p, rra_a), 1, rra_sum > 255),
        64,
        band(band(bxor(a, rra_a), bxor(shift_v, rra_a)), 128) != 0
      )

    composite = o == op(:SLO) or o == op(:RLA) or o == op(:SRE)

    shift_result_a =
      Nx.select(
        o == op(:RRA),
        rra_a,
        Nx.select(composite, band(shift_a, 255), Nx.select(m == mode(:acc), shift_v, a))
      )

    shift_result_p =
      Nx.select(
        o == op(:RRA),
        rra_p,
        Nx.select(composite or m == mode(:acc), zn(shift_p, shift_result_a), zn(shift_p, shift_v))
      )

    anc_a = band(a, v)
    anc_p = set(zn(p, anc_a), 1, band(anc_a, 128) != 0)
    alr_t = band(a, v)
    alr_a = shr(alr_t, 1)
    alr_p = set(zn(p, alr_a), 1, band(alr_t, 1) != 0)
    arr_a = bor(shr(band(a, v), 1), shl(band(p, 1), 7))

    arr_p =
      set(
        set(zn(p, arr_a), 1, band(arr_a, 64) != 0),
        64,
        band(bxor(shr(arr_a, 6), shr(arr_a, 5)), 1) != 0
      )

    sbx_t = band(a, x)
    sbx_x = band(sbx_t - v, 255)
    sbx_p = set(zn(p, sbx_x), 1, sbx_t >= v)

    pull1_sp = band(sp + 1, 255)
    pull2_sp = band(sp + 2, 255)
    pull3_sp = band(sp + 3, 255)
    pull1 = Bus.peek(s, 256 + pull1_sp)
    pull2 = Bus.peek(s, 256 + pull2_sp)
    pull3 = Bus.peek(s, 256 + pull3_sp)

    branch_on =
      Nx.select(
        h == 29,
        band(p, 1) == 0,
        Nx.select(
          h == 30,
          band(p, 1) != 0,
          Nx.select(
            h == 31,
            band(p, 2) == 0,
            Nx.select(
              h == 32,
              band(p, 2) != 0,
              Nx.select(
                h == 33,
                band(p, 128) == 0,
                Nx.select(
                  h == 34,
                  band(p, 128) != 0,
                  Nx.select(h == 35, band(p, 64) == 0, band(p, 64) != 0)
                )
              )
            )
          )
        )
      )

    is_branch = h >= 29 and h <= 36
    extra = Nx.select(is_branch and branch_on, 1 + cross(pc, addr), 0)

    next_a = a
    next_a = choose(h, 0, band(v, 255), next_a)
    next_a = choose(h, 8, band(x, 255), next_a)
    next_a = choose(h, 9, band(y, 255), next_a)
    next_a = choose(h, 12, band(a, v), next_a)
    next_a = choose(h, 13, bor(a, v), next_a)
    next_a = choose(h, 14, bxor(a, v), next_a)
    next_a = choose(h, 37, adc_a, next_a)
    next_a = choose(h, 38, sbc_a, next_a)
    next_a = choose(h, 40, rmw_a, next_a)
    next_a = choose(h, 41, shift_result_a, next_a)
    next_a = choose(h, 42, band(v, 255), next_a)
    next_a = choose(h, 44, anc_a, next_a)
    next_a = choose(h, 45, alr_a, next_a)
    next_a = choose(h, 46, arr_a, next_a)
    next_a = choose(h, 51, band(pull1, 255), next_a)

    next_x = x
    next_x = choose(h, 1, band(v, 255), next_x)
    next_x = choose(h, 6, band(a, 255), next_x)
    next_x = choose(h, 10, band(sp, 255), next_x)
    next_x = choose(h, 18, band(x + 1, 255), next_x)
    next_x = choose(h, 20, band(x - 1, 255), next_x)
    next_x = choose(h, 42, band(v, 255), next_x)
    next_x = choose(h, 47, sbx_x, next_x)

    next_y = y
    next_y = choose(h, 2, band(v, 255), next_y)
    next_y = choose(h, 7, band(a, 255), next_y)
    next_y = choose(h, 19, band(y + 1, 255), next_y)
    next_y = choose(h, 21, band(y - 1, 255), next_y)

    next_p = p
    next_p = choose(h, 0, zn(p, v), next_p)
    next_p = choose(h, 1, zn(p, v), next_p)
    next_p = choose(h, 2, zn(p, v), next_p)
    next_p = choose(h, 6, zn(p, a), next_p)
    next_p = choose(h, 7, zn(p, a), next_p)
    next_p = choose(h, 8, zn(p, x), next_p)
    next_p = choose(h, 9, zn(p, y), next_p)
    next_p = choose(h, 10, zn(p, sp), next_p)
    next_p = choose(h, 12, zn(p, band(a, v)), next_p)
    next_p = choose(h, 13, zn(p, bor(a, v)), next_p)
    next_p = choose(h, 14, zn(p, bxor(a, v)), next_p)
    next_p = choose(h, 15, compare_p(p, a, v), next_p)
    next_p = choose(h, 16, compare_p(p, x, v), next_p)
    next_p = choose(h, 17, compare_p(p, y, v), next_p)
    next_p = choose(h, 18, zn(p, x + 1), next_p)
    next_p = choose(h, 19, zn(p, y + 1), next_p)
    next_p = choose(h, 20, zn(p, x - 1), next_p)
    next_p = choose(h, 21, zn(p, y - 1), next_p)
    next_p = choose(h, 22, set(p, 1, 0), next_p)
    next_p = choose(h, 23, set(p, 1, 1), next_p)
    next_p = choose(h, 24, set(p, 4, 0), next_p)
    next_p = choose(h, 25, set(p, 4, 1), next_p)
    next_p = choose(h, 26, set(p, 8, 0), next_p)
    next_p = choose(h, 27, set(p, 8, 1), next_p)
    next_p = choose(h, 28, set(p, 64, 0), next_p)
    next_p = choose(h, 37, adc_p, next_p)
    next_p = choose(h, 38, sbc_p, next_p)
    bit_p = set(set(set(p, 2, band(a, v) == 0), 128, band(v, 128) != 0), 64, band(v, 64) != 0)
    next_p = choose(h, 39, bit_p, next_p)
    next_p = choose(h, 40, rmw_p, next_p)
    next_p = choose(h, 41, shift_result_p, next_p)
    next_p = choose(h, 42, zn(p, v), next_p)
    next_p = choose(h, 44, anc_p, next_p)
    next_p = choose(h, 45, alr_p, next_p)
    next_p = choose(h, 46, arr_p, next_p)
    next_p = choose(h, 47, sbx_p, next_p)
    next_p = choose(h, 51, zn(p, pull1), next_p)
    next_p = choose(h, 52, bor(band(pull1, 239), 32), next_p)
    next_p = choose(h, 56, bor(band(pull1, 239), 32), next_p)
    next_p = choose(h, 57, bor(p, 4), next_p)

    next_sp = Nx.select(h == 11, band(x, 255), sp)
    next_sp = Nx.select(h == 49 or h == 50, band(sp - 1, 255), next_sp)
    next_sp = Nx.select(h == 54, band(sp - 2, 255), next_sp)
    next_sp = Nx.select(h == 51 or h == 52, pull1_sp, next_sp)
    next_sp = Nx.select(h == 55, pull2_sp, next_sp)
    next_sp = Nx.select(h == 56, pull3_sp, next_sp)
    next_sp = Nx.select(h == 57, band(sp - 3, 255), next_sp)

    next_pc = Nx.select(is_branch and branch_on, addr, pc)
    next_pc = Nx.select(h == 53 or h == 54, addr, next_pc)
    next_pc = Nx.select(h == 55, band(bor(pull1, shl(pull2, 8)) + 1, 65535), next_pc)
    next_pc = Nx.select(h == 56, bor(pull2, shl(pull3, 8)), next_pc)
    brk_pc = band(pc + 1, 65535)
    next_pc = Nx.select(h == 57, bor(Bus.peek(s, 0xFFFE), shl(Bus.peek(s, 0xFFFF), 8)), next_pc)

    memory_write =
      h == 3 or h == 4 or h == 5 or h == 40 or (h == 41 and m != mode(:acc)) or h == 43 or h == 48

    memory_value =
      Nx.select(
        h == 3,
        a,
        Nx.select(
          h == 4,
          x,
          Nx.select(h == 5, y, Nx.select(h == 40, rmw_v, Nx.select(h == 41, shift_v, band(a, x))))
        )
      )

    sh_index = Nx.select(o == op(:SHX), y, x)
    sh_reg = Nx.select(o == op(:SHX), x, y)
    sh_base = band(addr - sh_index, 65535)
    sh_value = band(band(sh_reg, shr(sh_base, 8) + 1), 255)
    sh_target = Nx.select(cross(sh_base, addr) != 0, bor(band(addr, 255), shl(sh_value, 8)), addr)
    memory_value = Nx.select(h == 48, sh_value, memory_value)
    memory_addr = Nx.select(h == 48, sh_target, addr)

    s = %{
      s
      | a: band(next_a, 255),
        x: band(next_x, 255),
        y: band(next_y, 255),
        sp: band(next_sp, 255),
        p: band(next_p, 255),
        pc: band(next_pc, 65535)
    }

    s = masked_write(s, memory_write, memory_addr, memory_value)
    s = masked_write(s, h == 49 or h == 50, 256 + sp, Nx.select(h == 49, a, bor(p, 16)))

    s =
      masked_write(
        s,
        h == 54 or h == 57,
        256 + sp,
        Nx.select(h == 54, shr(band(pc - 1, 65535), 8), shr(brk_pc, 8))
      )

    s =
      masked_write(
        s,
        h == 54 or h == 57,
        256 + band(sp - 1, 255),
        Nx.select(h == 54, band(pc - 1, 255), band(brk_pc, 255))
      )

    s = masked_write(s, h == 57, 256 + band(sp - 2, 255), bor(p, 16))
    {s, extra}
  end

  defn execute(s, o, m, addr) do
    # Operand reads occur only for operations that really read memory.
    reads = reads_operand(o, m)

    {v, s} = if reads, do: Bus.read(s, addr), else: {s.a, s}

    handler =
      Nx.take(
        Nx.tensor(
          [
            37,
            45,
            44,
            12,
            46,
            41,
            29,
            30,
            32,
            39,
            34,
            31,
            33,
            57,
            35,
            36,
            22,
            26,
            24,
            28,
            15,
            16,
            17,
            40,
            40,
            20,
            21,
            14,
            40,
            18,
            19,
            40,
            53,
            54,
            42,
            0,
            1,
            2,
            41,
            42,
            58,
            13,
            49,
            50,
            51,
            52,
            41,
            41,
            41,
            41,
            56,
            55,
            43,
            38,
            47,
            23,
            27,
            25,
            48,
            48,
            41,
            41,
            3,
            4,
            5,
            6,
            7,
            10,
            8,
            11,
            9,
            58
          ],
          type: :s32
        ),
        o
      )

    {s, extra} =
      if handler < 29 do
        if handler < 14 do
          if handler < 7 do
            if handler < 3 do
              if handler < 1 do
                {load(s, :a, v), zero()}
              else
                if handler < 2 do
                  {load(s, :x, v), zero()}
                else
                  {load(s, :y, v), zero()}
                end
              end
            else
              if handler < 5 do
                if handler < 4 do
                  {Bus.write(s, addr, s.a), zero()}
                else
                  {Bus.write(s, addr, s.x), zero()}
                end
              else
                if handler < 6 do
                  {Bus.write(s, addr, s.y), zero()}
                else
                  {load(s, :x, s.a), zero()}
                end
              end
            end
          else
            if handler < 10 do
              if handler < 8 do
                {load(s, :y, s.a), zero()}
              else
                if handler < 9 do
                  {load(s, :a, s.x), zero()}
                else
                  {load(s, :a, s.y), zero()}
                end
              end
            else
              if handler < 12 do
                if handler < 11 do
                  {load(s, :x, s.sp), zero()}
                else
                  {%{s | sp: s.x}, zero()}
                end
              else
                if handler < 13 do
                  {load(s, :a, band(s.a, v)), zero()}
                else
                  {load(s, :a, bor(s.a, v)), zero()}
                end
              end
            end
          end
        else
          if handler < 21 do
            if handler < 17 do
              if handler < 15 do
                {load(s, :a, bxor(s.a, v)), zero()}
              else
                if handler < 16 do
                  {compare(s, s.a, v), zero()}
                else
                  {compare(s, s.x, v), zero()}
                end
              end
            else
              if handler < 19 do
                if handler < 18 do
                  {compare(s, s.y, v), zero()}
                else
                  {load(s, :x, s.x + 1), zero()}
                end
              else
                if handler < 20 do
                  {load(s, :y, s.y + 1), zero()}
                else
                  {load(s, :x, s.x - 1), zero()}
                end
              end
            end
          else
            if handler < 25 do
              if handler < 23 do
                if handler < 22 do
                  {load(s, :y, s.y - 1), zero()}
                else
                  {%{s | p: set(s.p, 1, 0)}, zero()}
                end
              else
                if handler < 24 do
                  {%{s | p: set(s.p, 1, 1)}, zero()}
                else
                  {%{s | p: set(s.p, 4, 0)}, zero()}
                end
              end
            else
              if handler < 27 do
                if handler < 26 do
                  {%{s | p: set(s.p, 4, 1)}, zero()}
                else
                  {%{s | p: set(s.p, 8, 0)}, zero()}
                end
              else
                if handler < 28 do
                  {%{s | p: set(s.p, 8, 1)}, zero()}
                else
                  {%{s | p: set(s.p, 64, 0)}, zero()}
                end
              end
            end
          end
        end
      else
        if handler < 44 do
          if handler < 36 do
            if handler < 32 do
              if handler < 30 do
                branch(s, band(s.p, 1) == 0, addr)
              else
                if handler < 31 do
                  branch(s, band(s.p, 1) != 0, addr)
                else
                  branch(s, band(s.p, 2) == 0, addr)
                end
              end
            else
              if handler < 34 do
                if handler < 33 do
                  branch(s, band(s.p, 2) != 0, addr)
                else
                  branch(s, band(s.p, 128) == 0, addr)
                end
              else
                if handler < 35 do
                  branch(s, band(s.p, 128) != 0, addr)
                else
                  branch(s, band(s.p, 64) == 0, addr)
                end
              end
            end
          else
            if handler < 40 do
              if handler < 38 do
                if handler < 37 do
                  branch(s, band(s.p, 64) != 0, addr)
                else
                  {adc(s, v), zero()}
                end
              else
                if handler < 39 do
                  {adc(s, bxor(v, 255)), zero()}
                else
                  {%{
                     s
                     | p:
                         set(
                           set(set(s.p, 2, band(s.a, v) == 0), 128, band(v, 128) != 0),
                           64,
                           band(v, 64) != 0
                         )
                   }, zero()}
                end
              end
            else
              if handler < 42 do
                if handler < 41 do
                  v = band(v + Nx.select(o == op(:INC) or o == op(:ISB), 1, -1), 255)
                  s = Bus.write(s, addr, v)

                  s =
                    cond do
                      o == op(:DCP) -> compare(s, s.a, v)
                      o == op(:ISB) -> adc(s, bxor(v, 255))
                      true -> %{s | p: zn(s.p, v)}
                    end

                  {s, zero()}
                else
                  {p, v} = shift(s.p, v, o)
                  s = %{s | p: p}
                  s = if m == mode(:acc), do: load(s, :a, v), else: Bus.write(s, addr, v)

                  s =
                    cond do
                      o == op(:SLO) -> load(s, :a, bor(s.a, v))
                      o == op(:RLA) -> load(s, :a, band(s.a, v))
                      o == op(:SRE) -> load(s, :a, bxor(s.a, v))
                      o == op(:RRA) -> adc(s, v)
                      true -> %{s | p: zn(s.p, v)}
                    end

                  {s, zero()}
                end
              else
                if handler < 43 do
                  {load(load(s, :a, v), :x, v), zero()}
                else
                  {Bus.write(s, addr, band(s.a, s.x)), zero()}
                end
              end
            end
          end
        else
          if handler < 51 do
            if handler < 47 do
              if handler < 45 do
                s = load(s, :a, band(s.a, v))
                {%{s | p: set(s.p, 1, band(s.a, 128) != 0)}, zero()}
              else
                if handler < 46 do
                  t = band(s.a, v)
                  s = load(s, :a, shr(t, 1))
                  {%{s | p: set(s.p, 1, band(t, 1) != 0)}, zero()}
                else
                  a = bor(shr(band(s.a, v), 1), shl(band(s.p, 1), 7))
                  s = load(s, :a, a)

                  {%{
                     s
                     | p:
                         set(
                           set(s.p, 1, band(a, 64) != 0),
                           64,
                           band(bxor(shr(a, 6), shr(a, 5)), 1) != 0
                         )
                   }, zero()}
                end
              end
            else
              if handler < 49 do
                if handler < 48 do
                  t = band(s.a, s.x)
                  s = load(s, :x, t - v)
                  {%{s | p: set(s.p, 1, t >= v)}, zero()}
                else
                  index = Nx.select(o == op(:SHX), s.y, s.x)
                  reg = Nx.select(o == op(:SHX), s.x, s.y)
                  base = band(addr - index, 65535)
                  value = band(band(reg, shr(base, 8) + 1), 255)

                  target =
                    Nx.select(cross(base, addr) != 0, bor(band(addr, 255), shl(value, 8)), addr)

                  {Bus.write(s, target, value), zero()}
                end
              else
                if handler < 50 do
                  {push(s, s.a), zero()}
                else
                  {push(s, bor(s.p, 16)), zero()}
                end
              end
            end
          else
            if handler < 55 do
              if handler < 53 do
                if handler < 52 do
                  {s, v} = pull(s)
                  {load(s, :a, v), zero()}
                else
                  {s, v} = pull(s)
                  {%{s | p: bor(band(v, 239), 32)}, zero()}
                end
              else
                if handler < 54 do
                  {%{s | pc: addr}, zero()}
                else
                  ret = band(s.pc - 1, 65535)
                  s = push(push(s, shr(ret, 8)), band(ret, 255))
                  {%{s | pc: addr}, zero()}
                end
              end
            else
              if handler < 57 do
                if handler < 56 do
                  {s, lo} = pull(s)
                  {s, hi} = pull(s)
                  {%{s | pc: band(bor(lo, shl(hi, 8)) + 1, 65535)}, zero()}
                else
                  {s, p} = pull(s)
                  {s, lo} = pull(s)
                  {s, hi} = pull(s)
                  {%{s | p: bor(band(p, 239), 32), pc: bor(lo, shl(hi, 8))}, zero()}
                end
              else
                if handler < 58 do
                  pc = band(s.pc + 1, 65535)
                  s = push(push(push(s, shr(pc, 8)), band(pc, 255)), bor(s.p, 16))
                  {%{s | p: bor(s.p, 4), pc: word(s, 0xFFFE)}, zero()}
                else
                  {s, zero()}
                end
              end
            end
          end
        end
      end

    {s, extra}
  end

  defnp adc(s, v) do
    sum = s.a + v + band(s.p, 1)
    a = band(sum, 255)
    p = set(set(zn(s.p, a), 1, sum > 255), 64, band(band(bxor(s.a, a), bxor(v, a)), 128) != 0)
    %{s | a: a, p: p}
  end

  defnp(compare(s, reg, v), do: %{s | p: set(zn(s.p, band(reg - v, 255)), 1, reg >= v)})

  defnp shift(p, v, o) do
    cond do
      o == op(:ASL) or o == op(:SLO) ->
        {set(p, 1, band(v, 128) != 0), band(shl(v, 1), 255)}

      o == op(:LSR) or o == op(:SRE) ->
        {set(p, 1, band(v, 1) != 0), shr(v, 1)}

      o == op(:ROL) or o == op(:RLA) ->
        {set(p, 1, band(v, 128) != 0), band(bor(shl(v, 1), band(p, 1)), 255)}

      true ->
        {set(p, 1, band(v, 1) != 0), bor(shr(v, 1), shl(band(p, 1), 7))}
    end
  end

  defnp push(s, v) do
    s = Bus.write(s, 256 + s.sp, v)
    %{s | sp: band(s.sp - 1, 255)}
  end

  defnp pull(s) do
    s = %{s | sp: band(s.sp + 1, 255)}
    {s, Bus.peek(s, 256 + s.sp)}
  end

  defnp branch(s, on, target) do
    extra = Nx.select(on, 1 + cross(s.pc, target), 0)
    {%{s | pc: Nx.select(on, target, s.pc)}, extra}
  end

  defnp(word(s, a), do: bor(Bus.peek(s, a), shl(Bus.peek(s, band(a + 1, 65535)), 8)))
  defnp(cross(a, b), do: Nx.as_type(band(a, 65280) != band(b, 65280), :s32))
  defnp(compare_p(p, reg, v), do: set(zn(p, band(reg - v, 255)), 1, reg >= v))
  defnp(choose(handler, wanted, value, default), do: Nx.select(handler == wanted, value, default))

  deftransformp masked_write(s, enabled, address, value) do
    if Map.has_key?(s, :write_count),
      do: masked_queue_write(s, enabled, address, value),
      else: masked_direct_write(s, enabled, address, value)
  end

  defn masked_queue_write(s, enabled, address, value) do
    a = band(address, 65535)
    v = band(value, 255)
    external = a >= 0x2000 and a < 0x6000
    accepted = enabled and not external
    barrier = enabled and external and s.reason == 0
    n = s.write_count

    %{
      s
      | write_count: n + Nx.as_type(accepted, :s32),
        write_addr0: Nx.select(accepted and n == 0, a, s.write_addr0),
        write_addr1: Nx.select(accepted and n == 1, a, s.write_addr1),
        write_addr2: Nx.select(accepted and n == 2, a, s.write_addr2),
        write_value0: Nx.select(accepted and n == 0, v, s.write_value0),
        write_value1: Nx.select(accepted and n == 1, v, s.write_value1),
        write_value2: Nx.select(accepted and n == 2, v, s.write_value2),
        reason: Nx.select(barrier, 3, s.reason),
        event_addr: Nx.select(barrier, a, s.event_addr),
        event_value: Nx.select(barrier, v, s.event_value)
    }
  end

  defn masked_direct_write(s, enabled, address, value) do
    if enabled, do: Bus.write(s, address, value), else: s
  end

  defnp(zn(p, v), do: set(set(p, 2, band(v, 255) == 0), 128, band(v, 128) != 0))
  defnp(set(p, mask, on), do: Nx.select(on != 0, bor(p, mask), band(p, bxor(mask, 255))))
  defnp(zero(), do: Nx.tensor(0, type: :s32))
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(bxor(a, b), do: Nx.bitwise_xor(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
  defnp(shl(a, b), do: Nx.left_shift(a, b))

  deftransformp(load(s, reg, v),
    do: Map.merge(s, %{reg => Nx.bitwise_and(v, 255), p: zn(s.p, v)})
  )
end
