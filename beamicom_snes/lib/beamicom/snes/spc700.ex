defmodule Beamicom.SNES.SPC700 do
  @moduledoc "Native Sony SPC700 interpreter and S-SMP register boundary."

  import Bitwise
  alias Beamicom.SNES.DSP

  @compile {:inline,
            direct: 2, fetch: 1, ram_get: 2, memory_get: 2, signed: 1, carry_value: 1, flag: 3}

  @n 0x80
  @v 0x40
  @p 0x20
  @b 0x10
  @h 0x08
  @i 0x04
  @z 0x02
  @c 0x01
  @ipl <<0xCD, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0, 0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5,
         0x78, 0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4, 0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B,
         0xE4, 0xF5, 0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB, 0x01, 0x10, 0xEF, 0x7E, 0xF4,
         0x10, 0xEB, 0xBA, 0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD, 0x5D, 0xD0, 0xDB, 0x1F,
         0x00, 0x00, 0xC0, 0xFF>>

  defstruct ram: nil,
            a: 0,
            x: 0,
            y: 0,
            sp: 0xEF,
            pc: 0,
            psw: 0,
            input_ports: {0, 0, 0, 0},
            output_ports: {0, 0, 0, 0},
            control: 0x80,
            dsp_addr: 0,
            dsp: nil,
            dsp_events: [],
            aux: {0, 0},
            timer_targets: {0, 0, 0},
            timer_stages: {0, 0, 0},
            timer_outputs: {0, 0, 0},
            timer_phase: {0, 0, 0},
            timer_last_cycles: {0, 0, 0},
            cycles: 0,
            cycle_credit: 0,
            stopped?: false,
            error: nil

  @type t :: %__MODULE__{}

  def new(ram, pc, input_ports \\ {0, 0, 0, 0}) do
    %__MODULE__{ram: ram, pc: pc &&& 0xFFFF, input_ports: input_ports, dsp: DSP.new()}
  end

  def put_input_port(%__MODULE__{} = spc, port, value),
    do: %{spc | input_ports: put_elem(spc.input_ports, port, value &&& 0xFF)}

  def run(%__MODULE__{} = spc, cycles) when is_integer(cycles) do
    {spc, cycle_credit} = run_cycles(spc, spc.cycle_credit + cycles)
    %{spc | cycle_credit: cycle_credit}
  end

  @doc false
  def run_with_dsp_events(%__MODULE__{} = spc, cycles) when is_integer(cycles) do
    spc = run(%{spc | dsp_events: []}, cycles)
    {Enum.reverse(spc.dsp_events), %{spc | dsp_events: []}}
  end

  defp run_cycles(spc, cycles) when cycles <= 0, do: {spc, cycles}

  defp run_cycles(%__MODULE__{error: error} = spc, _cycles) when not is_nil(error),
    do: {spc, 0}

  defp run_cycles(%__MODULE__{stopped?: true} = spc, _cycles), do: {spc, 0}

  defp run_cycles(spc, cycles) do
    {opcode, spc} = fetch(spc)

    case execute(opcode, spc) do
      {:ok, next_spc, used} ->
        spc = %{next_spc | cycles: next_spc.cycles + used}

        run_cycles(spc, cycles - used)

      {:error, reason, spc} ->
        {%{spc | error: {reason, spc.pc - 1 &&& 0xFFFF}}, 0}
    end
  end

  # Branches and flag-only operations.
  defp execute(op, spc) when op in [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0] do
    {offset, spc} = fetch(spc)

    taken? =
      case op do
        0x10 -> (spc.psw &&& @n) == 0
        0x30 -> (spc.psw &&& @n) != 0
        0x50 -> (spc.psw &&& @v) == 0
        0x70 -> (spc.psw &&& @v) != 0
        0x90 -> (spc.psw &&& @c) == 0
        0xB0 -> (spc.psw &&& @c) != 0
        0xD0 -> (spc.psw &&& @z) == 0
        0xF0 -> (spc.psw &&& @z) != 0
      end

    {:ok, if(taken?, do: branch(spc, offset), else: spc), if(taken?, do: 4, else: 2)}
  end

  defp execute(0x2F, spc) do
    {offset, spc} = fetch(spc)
    {:ok, branch(spc, offset), 4}
  end

  defp execute(op, spc) when op in [0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0, 0xED] do
    psw =
      case op do
        0x20 -> spc.psw &&& bnot(@p)
        0x40 -> spc.psw ||| @p
        0x60 -> spc.psw &&& bnot(@c)
        0x80 -> spc.psw ||| @c
        0xA0 -> spc.psw ||| @i
        0xC0 -> spc.psw &&& bnot(@i)
        0xE0 -> spc.psw &&& bnot(@v ||| @h)
        0xED -> bxor(spc.psw, @c)
      end

    {:ok, %{spc | psw: psw}, if(op in [0xA0, 0xC0, 0xED], do: 3, else: 2)}
  end

  defp execute(0x00, spc), do: {:ok, spc, 2}

  defp execute(0x0F, spc) do
    spc = spc |> push(spc.pc >>> 8) |> push(spc.pc) |> push(spc.psw)
    {target, spc} = read_word(spc, 0xFFDE)
    psw = spc.psw |> bor(@b) |> band(bnot(@i))
    {:ok, %{spc | pc: target, psw: psw}, 8}
  end

  # MOV register immediates and register transfers.
  defp execute(op, spc) when op in [0xE8, 0xCD, 0x8D] do
    {value, spc} = fetch(spc)
    register = %{0xE8 => :a, 0xCD => :x, 0x8D => :y}[op]
    {:ok, spc |> Map.put(register, value) |> set_nz(value), 2}
  end

  defp execute(op, spc) when op in [0x5D, 0x7D, 0x9D, 0xBD, 0xDD, 0xFD] do
    {register, value} =
      case op do
        0x5D -> {:x, spc.a}
        0x7D -> {:a, spc.x}
        0x9D -> {:x, spc.sp}
        0xBD -> {:sp, spc.x}
        0xDD -> {:a, spc.y}
        0xFD -> {:y, spc.a}
      end

    spc = Map.put(spc, register, value)
    {:ok, if(register == :sp, do: spc, else: set_nz(spc, value)), 2}
  end

  # MOV loads.
  defp execute(op, spc)
       when op in [0xE4, 0xF4, 0xE5, 0xF5, 0xF6, 0xE6, 0xE7, 0xF7] do
    {address, spc} = address_for(op, spc)
    {value, spc} = read(spc, address)
    {:ok, %{spc | a: value} |> set_nz(value), load_cycles(op)}
  end

  defp execute(op, spc) when op in [0xF8, 0xF9, 0xE9] do
    {address, spc} = address_for(op, spc)
    {value, spc} = read(spc, address)
    {:ok, %{spc | x: value} |> set_nz(value), if(op == 0xF8, do: 3, else: 4)}
  end

  defp execute(op, spc) when op in [0xEB, 0xFB, 0xEC] do
    {address, spc} = address_for(op, spc)
    {value, spc} = read(spc, address)
    {:ok, %{spc | y: value} |> set_nz(value), if(op == 0xEB, do: 3, else: 4)}
  end

  # MOV stores.
  defp execute(op, spc)
       when op in [0xC4, 0xD4, 0xC5, 0xD5, 0xD6, 0xC6, 0xC7, 0xD7] do
    {address, spc} = address_for(op, spc)
    {:ok, write(spc, address, spc.a), store_cycles(op)}
  end

  defp execute(op, spc) when op in [0xD8, 0xD9, 0xC9] do
    {address, spc} = address_for(op, spc)
    {:ok, write(spc, address, spc.x), if(op == 0xD8, do: 4, else: 5)}
  end

  defp execute(op, spc) when op in [0xCB, 0xDB, 0xCC] do
    {address, spc} = address_for(op, spc)
    {:ok, write(spc, address, spc.y), if(op == 0xCB, do: 4, else: 5)}
  end

  defp execute(0x8F, spc) do
    {value, spc} = fetch(spc)
    {dp, spc} = fetch(spc)
    {:ok, write(spc, direct(spc, dp), value), 5}
  end

  defp execute(0xFA, spc) do
    {source, spc} = fetch(spc)
    {destination, spc} = fetch(spc)
    {value, spc} = read(spc, direct(spc, source))
    {:ok, write(spc, direct(spc, destination), value), 5}
  end

  defp execute(0xAF, spc) do
    spc = write(spc, direct(spc, spc.x), spc.a)
    {:ok, %{spc | x: spc.x + 1 &&& 0xFF}, 4}
  end

  defp execute(0xBF, spc) do
    {value, spc} = read(spc, direct(spc, spc.x))
    {:ok, %{spc | a: value, x: spc.x + 1 &&& 0xFF} |> set_nz(value), 4}
  end

  # OR/AND/EOR/CMP/ADC/SBC A,address and A,#immediate.
  defp execute(op, spc)
       when (op &&& 0x1F) in [0x04, 0x05, 0x06, 0x07, 0x08] and
              (op &&& 0xE0) in [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0] do
    operation = alu_operation(op)

    {value, spc, cycles} =
      if (op &&& 0x0F) == 0x08 do
        {value, spc} = fetch(spc)
        {value, spc, 2}
      else
        {address, spc} = address_for(op, spc)
        {value, spc} = read(spc, address)
        {value, spc, load_cycles(op)}
      end

    {:ok, alu_a(spc, operation, value), cycles}
  end

  defp execute(op, spc)
       when (op &&& 0x1F) in [0x04, 0x05, 0x06, 0x07] and
              (op &&& 0xE0) in [0xC0, 0xE0] do
    {address, spc} = address_for(op, spc)
    {value, spc} = read(spc, address)
    {:ok, compare(spc, spc.a, value), load_cycles(op)}
  end

  defp execute(op, spc)
       when (op &&& 0x1F) in [0x14, 0x15, 0x16, 0x17] and
              (op &&& 0xE0) in [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0] do
    {address, spc} = address_for(op, spc)
    {value, spc} = read(spc, address)
    {:ok, alu_a(spc, alu_operation(op), value), load_cycles(op)}
  end

  # Memory destination ALU forms: immediate,dp and source-dp,destination-dp.
  defp execute(op, spc)
       when (op &&& 0x1F) in [0x18, 0x09] and
              (op &&& 0xE0) in [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0] do
    {source, destination, spc} = memory_alu_operands(op, spc)
    {left, spc} = read(spc, destination)
    operation = alu_operation(op)

    if operation == :cmp do
      {:ok, compare(spc, left, source), if((op &&& 0x1F) == 0x18, do: 5, else: 6)}
    else
      {result, spc} = alu_value(spc, operation, left, source)
      {:ok, write(spc, destination, result), if((op &&& 0x1F) == 0x18, do: 5, else: 6)}
    end
  end

  # (X),(Y) memory ALU forms.
  defp execute(op, spc)
       when (op &&& 0x1F) == 0x19 and
              (op &&& 0xE0) in [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0] do
    x_address = direct(spc, spc.x)
    y_address = direct(spc, spc.y)
    {left, spc} = read(spc, x_address)
    {right, spc} = read(spc, y_address)
    operation = alu_operation(op)

    if operation == :cmp do
      {:ok, compare(spc, left, right), 5}
    else
      {result, spc} = alu_value(spc, operation, left, right)
      {:ok, write(spc, x_address, result), 5}
    end
  end

  # CMP X/Y.
  defp execute(op, spc) when op in [0xC8, 0x3E, 0x1E, 0xAD, 0x7E, 0x5E] do
    {register, mode} =
      case op do
        0xC8 -> {:x, :immediate}
        0x3E -> {:x, :direct}
        0x1E -> {:x, :absolute}
        0xAD -> {:y, :immediate}
        0x7E -> {:y, :direct}
        0x5E -> {:y, :absolute}
      end

    {value, spc} = fetch_operand(spc, mode)
    cycles = %{immediate: 2, direct: 3, absolute: 4}[mode]
    {:ok, compare(spc, Map.fetch!(spc, register), value), cycles}
  end

  # INC/DEC registers.
  defp execute(op, spc) when op in [0x1D, 0x3D, 0x9C, 0xBC, 0xDC, 0xFC] do
    {register, delta} =
      case op do
        0x1D -> {:x, -1}
        0x3D -> {:x, 1}
        0x9C -> {:a, -1}
        0xBC -> {:a, 1}
        0xDC -> {:y, -1}
        0xFC -> {:y, 1}
      end

    value = Map.fetch!(spc, register) + delta &&& 0xFF
    {:ok, spc |> Map.put(register, value) |> set_nz(value), 2}
  end

  # INC/DEC/ASL/ROL/LSR/ROR memory and accumulator.
  defp execute(op, spc)
       when op in [
              0x0B,
              0x0C,
              0x1B,
              0x2B,
              0x2C,
              0x3B,
              0x4B,
              0x4C,
              0x5B,
              0x6B,
              0x6C,
              0x7B,
              0x8B,
              0x8C,
              0x9B,
              0xAB,
              0xAC,
              0xBB
            ] do
    {address, spc} = rmw_address(op, spc)
    {value, spc} = read(spc, address)
    {value, spc} = rmw_value(spc, op, value)
    cycles = if (op &&& 0x0F) == 0x0C or (op &&& 0x1F) == 0x1B, do: 5, else: 4
    {:ok, write(spc, address, value), cycles}
  end

  defp execute(op, spc) when op in [0x1C, 0x3C, 0x5C, 0x7C] do
    {value, spc} = rmw_value(spc, op, spc.a)
    {:ok, %{spc | a: value}, 2}
  end

  # Word moves/arithmetic.
  defp execute(0xBA, spc) do
    {dp, spc} = fetch(spc)
    {word, spc} = read_dp_word(spc, dp)
    {:ok, %{spc | a: word &&& 0xFF, y: word >>> 8} |> set_nz16(word), 5}
  end

  defp execute(0xDA, spc) do
    {dp, spc} = fetch(spc)
    {:ok, write_dp_word(spc, dp, spc.a ||| spc.y <<< 8), 5}
  end

  defp execute(op, spc) when op in [0x1A, 0x3A] do
    {dp, spc} = fetch(spc)
    {word, spc} = read_dp_word(spc, dp)
    word = word + if(op == 0x3A, do: 1, else: -1) &&& 0xFFFF
    {:ok, write_dp_word(set_nz16(spc, word), dp, word), 6}
  end

  defp execute(op, spc) when op in [0x5A, 0x7A, 0x9A] do
    {dp, spc} = fetch(spc)
    {right, spc} = read_dp_word(spc, dp)
    left = spc.a ||| spc.y <<< 8

    case op do
      0x5A -> {:ok, compare16(spc, left, right), 4}
      0x7A -> {:ok, addw(spc, left, right), 5}
      0x9A -> {:ok, subw(spc, left, right), 5}
    end
  end

  # Calls, returns, and table calls.
  defp execute(0x3F, spc) do
    {target, spc} = fetch_word(spc)
    spc = spc |> push(spc.pc >>> 8) |> push(spc.pc)
    {:ok, %{spc | pc: target}, 8}
  end

  defp execute(0x4F, spc) do
    {low, spc} = fetch(spc)
    spc = spc |> push(spc.pc >>> 8) |> push(spc.pc)
    {:ok, %{spc | pc: 0xFF00 ||| low}, 6}
  end

  defp execute(op, spc) when (op &&& 0x0F) == 1 do
    vector = 0xFFDE - (op >>> 4) * 2
    {target, spc} = read_word(spc, vector)
    spc = spc |> push(spc.pc >>> 8) |> push(spc.pc)
    {:ok, %{spc | pc: target}, 8}
  end

  defp execute(0x6F, spc) do
    {low, spc} = pop(spc)
    {high, spc} = pop(spc)
    {:ok, %{spc | pc: low ||| high <<< 8}, 5}
  end

  defp execute(0x7F, spc) do
    {psw, spc} = pop(spc)
    {low, spc} = pop(spc)
    {high, spc} = pop(spc)
    {:ok, %{spc | psw: psw, pc: low ||| high <<< 8}, 6}
  end

  defp execute(0x5F, spc) do
    {target, spc} = fetch_word(spc)
    {:ok, %{spc | pc: target}, 3}
  end

  defp execute(0x1F, spc) do
    {base, spc} = fetch_word(spc)
    {target, spc} = read_word(spc, base + spc.x &&& 0xFFFF)
    {:ok, %{spc | pc: target}, 6}
  end

  # Stack operations.
  defp execute(op, spc) when op in [0x0D, 0x2D, 0x4D, 0x6D] do
    value = %{0x0D => spc.psw, 0x2D => spc.a, 0x4D => spc.x, 0x6D => spc.y}[op]
    {:ok, push(spc, value), 4}
  end

  defp execute(op, spc) when op in [0x8E, 0xAE, 0xCE, 0xEE] do
    {value, spc} = pop(spc)
    register = %{0x8E => :psw, 0xAE => :a, 0xCE => :x, 0xEE => :y}[op]
    {:ok, Map.put(spc, register, value), 4}
  end

  # DBNZ and CBNE.
  defp execute(0xFE, spc) do
    {offset, spc} = fetch(spc)
    y = spc.y - 1 &&& 0xFF
    spc = %{spc | y: y}
    {:ok, if(y != 0, do: branch(spc, offset), else: spc), if(y != 0, do: 6, else: 4)}
  end

  defp execute(0x6E, spc) do
    {dp, spc} = fetch(spc)
    {offset, spc} = fetch(spc)
    address = direct(spc, dp)
    {value, spc} = read(spc, address)
    value = value - 1 &&& 0xFF
    spc = write(spc, address, value)
    {:ok, if(value != 0, do: branch(spc, offset), else: spc), if(value != 0, do: 7, else: 5)}
  end

  defp execute(op, spc) when op in [0x2E, 0xDE] do
    {dp, spc} = fetch(spc)
    {offset, spc} = fetch(spc)
    address = direct(spc, dp + if(op == 0xDE, do: spc.x, else: 0) &&& 0xFF)
    {value, spc} = read(spc, address)
    taken? = spc.a != value
    base_cycles = if op == 0xDE, do: 6, else: 5

    {:ok, if(taken?, do: branch(spc, offset), else: spc),
     base_cycles + if(taken?, do: 2, else: 0)}
  end

  # SET1/CLR1 and BBS/BBC.
  defp execute(op, spc) when (op &&& 0x0F) in [0x02, 0x12] do
    bit = op >>> 5
    {dp, spc} = fetch(spc)
    address = direct(spc, dp)
    {value, spc} = read(spc, address)
    value = if((op &&& 0x10) == 0, do: value ||| 1 <<< bit, else: value &&& bnot(1 <<< bit))
    {:ok, write(spc, address, value), 4}
  end

  defp execute(op, spc) when (op &&& 0x0F) in [0x03, 0x13] do
    bit = op >>> 5
    {dp, spc} = fetch(spc)
    {offset, spc} = fetch(spc)
    {value, spc} = read(spc, direct(spc, dp))
    set? = (value &&& 1 <<< bit) != 0
    taken? = if((op &&& 0x10) == 0, do: set?, else: not set?)
    {:ok, if(taken?, do: branch(spc, offset), else: spc), if(taken?, do: 7, else: 5)}
  end

  # TSET1/TCLR1.
  defp execute(op, spc) when op in [0x0E, 0x4E] do
    {address, spc} = fetch_word(spc)
    {value, spc} = read(spc, address)
    psw = spc |> set_nz(spc.a - value &&& 0xFF) |> Map.fetch!(:psw)
    value = if(op == 0x0E, do: value ||| spc.a, else: value &&& bnot(spc.a))
    {:ok, %{write(spc, address, value) | psw: psw}, 6}
  end

  # Carry operations on the SPC700's packed 13-bit address/3-bit selector.
  defp execute(op, spc) when op in [0x0A, 0x2A, 0x4A, 0x6A, 0x8A, 0xAA, 0xCA, 0xEA] do
    {operand, spc} = fetch_word(spc)
    address = operand &&& 0x1FFF
    bit = operand >>> 13
    {value, spc} = read(spc, address)
    selected? = (value &&& 1 <<< bit) != 0
    carry? = (spc.psw &&& @c) != 0

    case op do
      0x0A ->
        {:ok, carry(spc, carry? or selected?), 5}

      0x2A ->
        {:ok, carry(spc, carry? or not selected?), 5}

      0x4A ->
        {:ok, carry(spc, carry? and selected?), 4}

      0x6A ->
        {:ok, carry(spc, carry? and not selected?), 4}

      0x8A ->
        {:ok, carry(spc, carry? != selected?), 5}

      0xAA ->
        {:ok, carry(spc, selected?), 4}

      0xCA ->
        value = if(carry?, do: value ||| 1 <<< bit, else: value &&& bnot(1 <<< bit))
        {:ok, write(spc, address, value), 6}

      0xEA ->
        {:ok, write(spc, address, bxor(value, 1 <<< bit)), 5}
    end
  end

  # MUL, DIV, nibble exchange, and decimal adjust.
  defp execute(0xCF, spc) do
    value = spc.y * spc.a
    {:ok, %{spc | a: value &&& 0xFF, y: value >>> 8} |> set_nz(value >>> 8), 9}
  end

  defp execute(0x9E, spc) do
    divisor = spc.x <<< 9

    result =
      Enum.reduce(1..9, spc.a ||| spc.y <<< 8, fn _, value ->
        value = value <<< 1
        value = if (value &&& 0x20000) != 0, do: (value &&& 0x1FFFF) ||| 1, else: value
        value = if value >= divisor, do: bxor(value, 1), else: value
        if (value &&& 1) != 0, do: value - divisor &&& 0x1FFFF, else: value
      end)

    quotient = result &&& 0xFF
    remainder = result >>> 9 &&& 0xFF

    psw =
      spc.psw
      |> flag(@v, (result &&& 0x100) != 0)
      |> flag(@h, (spc.y &&& 0x0F) >= (spc.x &&& 0x0F))

    {:ok, %{spc | a: quotient, y: remainder, psw: psw} |> set_nz(quotient), 12}
  end

  defp execute(0x9F, spc) do
    value = (spc.a <<< 4 ||| spc.a >>> 4) &&& 0xFF
    {:ok, %{spc | a: value} |> set_nz(value), 5}
  end

  defp execute(op, spc) when op in [0xBE, 0xDF] do
    {value, psw} = decimal_adjust(spc.a, spc.psw, op)
    {:ok, %{spc | a: value, psw: psw} |> set_nz(value), 3}
  end

  defp execute(op, spc) when op in [0xEF, 0xFF], do: {:ok, %{spc | stopped?: true}, 7}

  defp execute(op, spc), do: {:error, {:unsupported_opcode, op}, spc}

  defp address_for(op, spc)
       when op not in [0xF8, 0xF9, 0xE9, 0xEB, 0xFB, 0xEC, 0xD8, 0xD9, 0xC9, 0xCB, 0xDB, 0xCC] do
    low = op &&& 0x1F

    case low do
      x when x in [0x04, 0x14] ->
        {dp, spc} = fetch(spc)
        {direct(spc, dp + if(x == 0x14, do: spc.x, else: 0) &&& 0xFF), spc}

      x when x in [0x05, 0x15, 0x16] ->
        {address, spc} = fetch_word(spc)
        index = if(x == 0x15, do: spc.x, else: if(x == 0x16, do: spc.y, else: 0))
        {address + index &&& 0xFFFF, spc}

      0x06 ->
        {direct(spc, spc.x), spc}

      x when x in [0x07, 0x17] ->
        {dp, spc} = fetch(spc)
        pointer = dp + if(x == 0x07, do: spc.x, else: 0) &&& 0xFF
        {address, spc} = read_dp_word(spc, pointer)
        {address + if(x == 0x17, do: spc.y, else: 0) &&& 0xFFFF, spc}

      0x18 ->
        {dp, spc} = fetch(spc)
        {direct(spc, dp), spc}

      0x19 ->
        {direct(spc, spc.x), spc}
    end
  end

  defp address_for(0xF8, spc) do
    {dp, spc} = fetch(spc)
    {direct(spc, dp), spc}
  end

  defp address_for(0xF9, spc) do
    {dp, spc} = fetch(spc)
    {direct(spc, dp + spc.y &&& 0xFF), spc}
  end

  defp address_for(0xE9, spc), do: absolute_operand(spc)
  defp address_for(0xEB, spc), do: direct_operand(spc, 0)
  defp address_for(0xFB, spc), do: direct_operand(spc, spc.x)
  defp address_for(0xEC, spc), do: absolute_operand(spc)
  defp address_for(0xD8, spc), do: direct_operand(spc, 0)
  defp address_for(0xD9, spc), do: direct_operand(spc, spc.y)
  defp address_for(0xC9, spc), do: absolute_operand(spc)
  defp address_for(0xCB, spc), do: direct_operand(spc, 0)
  defp address_for(0xDB, spc), do: direct_operand(spc, spc.x)
  defp address_for(0xCC, spc), do: absolute_operand(spc)

  defp direct_operand(spc, index) do
    {dp, spc} = fetch(spc)
    {direct(spc, dp + index &&& 0xFF), spc}
  end

  defp absolute_operand(spc) do
    {address, spc} = fetch_word(spc)
    {address, spc}
  end

  defp fetch_operand(spc, :immediate), do: fetch(spc)

  defp fetch_operand(spc, :direct) do
    {address, spc} = direct_operand(spc, 0)
    read(spc, address)
  end

  defp fetch_operand(spc, :absolute) do
    {address, spc} = absolute_operand(spc)
    read(spc, address)
  end

  defp memory_alu_operands(op, spc) do
    if (op &&& 0x1F) == 0x18 do
      {value, spc} = fetch(spc)
      {dp, spc} = fetch(spc)
      {value, direct(spc, dp), spc}
    else
      {source, spc} = fetch(spc)
      {destination, spc} = fetch(spc)
      {value, spc} = read(spc, direct(spc, source))
      {value, direct(spc, destination), spc}
    end
  end

  defp rmw_address(op, spc) do
    case op &&& 0x1F do
      x when x in [0x0B, 0x1B] -> direct_operand(spc, if(x == 0x1B, do: spc.x, else: 0))
      0x0C -> absolute_operand(spc)
    end
  end

  defp rmw_value(spc, op, value) do
    case op &&& 0xE0 do
      0x00 ->
        result = value <<< 1 &&& 0xFF
        {result, spc |> carry((value &&& 0x80) != 0) |> set_nz(result)}

      0x20 ->
        result = (value <<< 1 ||| carry_value(spc)) &&& 0xFF
        {result, spc |> carry((value &&& 0x80) != 0) |> set_nz(result)}

      0x40 ->
        result = value >>> 1
        {result, spc |> carry((value &&& 1) != 0) |> set_nz(result)}

      0x60 ->
        result = value >>> 1 ||| carry_value(spc) <<< 7
        {result, spc |> carry((value &&& 1) != 0) |> set_nz(result)}

      0x80 ->
        result = value - 1 &&& 0xFF
        {result, set_nz(spc, result)}

      0xA0 ->
        result = value + 1 &&& 0xFF
        {result, set_nz(spc, result)}
    end
  end

  defp alu_operation(op) do
    case op &&& 0xE0 do
      0x00 -> :or
      0x20 -> :and
      0x40 -> :eor
      0x60 -> :cmp
      0x80 -> :adc
      0xA0 -> :sbc
      0xC0 -> :mov
      0xE0 -> :mov
    end
  end

  defp alu_a(spc, :cmp, value), do: compare(spc, spc.a, value)
  defp alu_a(spc, :mov, value), do: %{spc | a: value} |> set_nz(value)

  defp alu_a(spc, operation, value) do
    {result, spc} = alu_value(spc, operation, spc.a, value)
    %{spc | a: result}
  end

  defp alu_value(spc, :or, left, right) do
    value = left ||| right
    {value, set_nz(spc, value)}
  end

  defp alu_value(spc, :and, left, right) do
    value = left &&& right
    {value, set_nz(spc, value)}
  end

  defp alu_value(spc, :eor, left, right) do
    value = bxor(left, right)
    {value, set_nz(spc, value)}
  end

  defp alu_value(spc, operation, left, right) when operation in [:adc, :sbc] do
    right = if operation == :sbc, do: bxor(right, 0xFF), else: right
    sum = left + right + carry_value(spc)
    result = sum &&& 0xFF
    overflow? = (bnot(bxor(left, right)) &&& bxor(left, result) &&& 0x80) != 0
    half? = (left &&& 0x0F) + (right &&& 0x0F) + carry_value(spc) > 0x0F

    spc =
      spc
      |> carry(sum > 0xFF)
      |> put_flag(@v, overflow?)
      |> put_flag(@h, half?)
      |> set_nz(result)

    {result, spc}
  end

  defp compare(spc, left, right) do
    result = left - right &&& 0xFF
    spc |> carry(left >= right) |> set_nz(result)
  end

  defp compare16(spc, left, right) do
    result = left - right &&& 0xFFFF
    spc |> carry(left >= right) |> set_nz16(result)
  end

  defp addw(spc, left, right) do
    sum = left + right
    result = sum &&& 0xFFFF
    overflow? = (bnot(bxor(left, right)) &&& bxor(left, result) &&& 0x8000) != 0
    half? = (left &&& 0x0FFF) + (right &&& 0x0FFF) > 0x0FFF

    %{spc | a: result &&& 0xFF, y: result >>> 8}
    |> carry(sum > 0xFFFF)
    |> put_flag(@v, overflow?)
    |> put_flag(@h, half?)
    |> set_nz16(result)
  end

  defp subw(spc, left, right) do
    result = left - right &&& 0xFFFF
    overflow? = (bxor(left, right) &&& bxor(left, result) &&& 0x8000) != 0
    half? = (left &&& 0x0FFF) >= (right &&& 0x0FFF)

    %{spc | a: result &&& 0xFF, y: result >>> 8}
    |> carry(left >= right)
    |> put_flag(@v, overflow?)
    |> put_flag(@h, half?)
    |> set_nz16(result)
  end

  defp decimal_adjust(value, psw, 0xDF) do
    {value, psw} =
      if value > 0x99 or (psw &&& @c) != 0, do: {value + 0x60, psw ||| @c}, else: {value, psw}

    value = if (value &&& 0x0F) > 9 or (psw &&& @h) != 0, do: value + 6, else: value
    {value &&& 0xFF, psw}
  end

  defp decimal_adjust(value, psw, 0xBE) do
    {value, psw} =
      if value > 0x99 or (psw &&& @c) == 0,
        do: {value - 0x60, psw &&& bnot(@c)},
        else: {value, psw}

    value = if (value &&& 0x0F) > 9 or (psw &&& @h) == 0, do: value - 6, else: value
    {value &&& 0xFF, psw}
  end

  defp load_cycles(op) do
    case op &&& 0x1F do
      0x04 -> 3
      0x05 -> 4
      0x06 -> 3
      0x07 -> 6
      0x14 -> 4
      0x15 -> 5
      0x16 -> 5
      0x17 -> 6
    end
  end

  defp store_cycles(op), do: load_cycles(op) + 1

  defp direct(spc, byte), do: if((spc.psw &&& @p) != 0, do: 0x100, else: 0) ||| (byte &&& 0xFF)

  defp fetch(spc) do
    value = memory_get(spc, spc.pc)
    {value, %{spc | pc: spc.pc + 1 &&& 0xFFFF}}
  end

  defp fetch_word(spc) do
    {low, spc} = fetch(spc)
    {high, spc} = fetch(spc)
    {low ||| high <<< 8, spc}
  end

  defp read_dp_word(spc, dp) do
    {low, spc} = read(spc, direct(spc, dp))
    {high, spc} = read(spc, direct(spc, dp + 1 &&& 0xFF))
    {low ||| high <<< 8, spc}
  end

  defp write_dp_word(spc, dp, value) do
    spc
    |> write(direct(spc, dp), value)
    |> write(direct(spc, dp + 1 &&& 0xFF), value >>> 8)
  end

  defp read_word(spc, address) do
    {low, spc} = read(spc, address)
    {high, spc} = read(spc, address + 1 &&& 0xFFFF)
    {low ||| high <<< 8, spc}
  end

  defp read(spc, address) do
    address = address &&& 0xFFFF

    case address do
      x when x in 0xF4..0xF7 ->
        {elem(spc.input_ports, x - 0xF4), spc}

      0xF2 ->
        {spc.dsp_addr, spc}

      0xF3 ->
        {DSP.read(spc.dsp, spc.dsp_addr), spc}

      0xF8 ->
        {elem(spc.aux, 0), spc}

      0xF9 ->
        {elem(spc.aux, 1), spc}

      x when x in 0xFD..0xFF ->
        index = x - 0xFD
        spc = sync_timer(spc, index)
        value = elem(spc.timer_outputs, index)
        {value, %{spc | timer_outputs: put_elem(spc.timer_outputs, index, 0)}}

      _ ->
        {memory_get(spc, address), spc}
    end
  end

  defp write(spc, address, value) do
    address = address &&& 0xFFFF
    value = value &&& 0xFF
    ram = :array.set(address, value, spc.ram)
    spc = %{spc | ram: ram}

    case address do
      0xF1 ->
        write_control(spc, value)

      0xF2 ->
        %{spc | dsp_addr: value}

      0xF3 ->
        if spc.dsp_addr < 0x80 do
          address = spc.dsp_addr

          %{
            spc
            | dsp: DSP.write(spc.dsp, address, value),
              dsp_events: [{spc.cycles, address, value} | spc.dsp_events]
          }
        else
          spc
        end

      x when x in 0xF4..0xF7 ->
        %{spc | output_ports: put_elem(spc.output_ports, x - 0xF4, value)}

      0xF8 ->
        %{spc | aux: put_elem(spc.aux, 0, value)}

      0xF9 ->
        %{spc | aux: put_elem(spc.aux, 1, value)}

      x when x in 0xFA..0xFC ->
        index = x - 0xFA
        spc = sync_timer(spc, index)
        %{spc | timer_targets: put_elem(spc.timer_targets, index, value)}

      _ ->
        spc
    end
  end

  defp write_control(spc, value) do
    spc = spc |> sync_timer(0) |> sync_timer(1) |> sync_timer(2)
    newly_enabled = value &&& bnot(spc.control) &&& 0x07

    {stages, outputs, phases, last_cycles} =
      Enum.reduce(
        0..2,
        {spc.timer_stages, spc.timer_outputs, spc.timer_phase, spc.timer_last_cycles},
        fn index, {stages, outputs, phases, last_cycles} ->
          if (newly_enabled &&& 1 <<< index) != 0 do
            {put_elem(stages, index, 0), put_elem(outputs, index, 0), put_elem(phases, index, 0),
             put_elem(last_cycles, index, spc.cycles)}
          else
            {stages, outputs, phases, put_elem(last_cycles, index, spc.cycles)}
          end
        end
      )

    inputs =
      spc.input_ports
      |> then(fn ports ->
        if((value &&& 0x10) != 0, do: ports |> put_elem(0, 0) |> put_elem(1, 0), else: ports)
      end)
      |> then(fn ports ->
        if((value &&& 0x20) != 0, do: ports |> put_elem(2, 0) |> put_elem(3, 0), else: ports)
      end)

    %{
      spc
      | control: value,
        input_ports: inputs,
        timer_stages: stages,
        timer_outputs: outputs,
        timer_phase: phases,
        timer_last_cycles: last_cycles
    }
  end

  defp sync_timer(spc, index) do
    last = elem(spc.timer_last_cycles, index)
    elapsed = spc.cycles - last
    last_cycles = put_elem(spc.timer_last_cycles, index, spc.cycles)

    if elapsed > 0 and (spc.control &&& 1 <<< index) != 0 do
      divider = if index == 2, do: 16, else: 128
      phase_total = elem(spc.timer_phase, index) + elapsed
      ticks = div(phase_total, divider)
      phase = rem(phase_total, divider)
      target_value = elem(spc.timer_targets, index)
      target = if target_value == 0, do: 256, else: target_value
      stage_total = elem(spc.timer_stages, index) + ticks
      output_ticks = div(stage_total, target)

      %{
        spc
        | timer_phase: put_elem(spc.timer_phase, index, phase),
          timer_stages: put_elem(spc.timer_stages, index, rem(stage_total, target)),
          timer_outputs:
            put_elem(
              spc.timer_outputs,
              index,
              elem(spc.timer_outputs, index) + output_ticks &&& 0x0F
            ),
          timer_last_cycles: last_cycles
      }
    else
      %{spc | timer_last_cycles: last_cycles}
    end
  end

  defp ram_get(ram, address), do: :array.get(address &&& 0xFFFF, ram)

  defp memory_get(spc, address) do
    address = address &&& 0xFFFF

    if address >= 0xFFC0 and (spc.control &&& 0x80) != 0,
      do: :binary.at(@ipl, address - 0xFFC0),
      else: ram_get(spc.ram, address)
  end

  defp push(spc, value) do
    ram = :array.set(0x100 ||| spc.sp, value &&& 0xFF, spc.ram)
    %{spc | ram: ram, sp: spc.sp - 1 &&& 0xFF}
  end

  defp pop(spc) do
    sp = spc.sp + 1 &&& 0xFF
    {:array.get(0x100 ||| sp, spc.ram), %{spc | sp: sp}}
  end

  defp branch(spc, offset), do: %{spc | pc: spc.pc + signed(offset) &&& 0xFFFF}
  defp signed(value) when value >= 0x80, do: value - 0x100
  defp signed(value), do: value

  defp carry_value(spc), do: if((spc.psw &&& @c) != 0, do: 1, else: 0)
  defp carry(spc, enabled?), do: %{spc | psw: flag(spc.psw, @c, enabled?)}
  defp put_flag(spc, bit, enabled?), do: %{spc | psw: flag(spc.psw, bit, enabled?)}
  defp flag(psw, bit, true), do: psw ||| bit
  defp flag(psw, bit, false), do: psw &&& bnot(bit)

  defp set_nz(spc, value) do
    psw = spc.psw &&& bnot(@n ||| @z)
    psw = if (value &&& 0xFF) == 0, do: psw ||| @z, else: psw
    psw = if (value &&& 0x80) != 0, do: psw ||| @n, else: psw
    %{spc | psw: psw}
  end

  defp set_nz16(spc, value) do
    psw = spc.psw &&& bnot(@n ||| @z)
    psw = if (value &&& 0xFFFF) == 0, do: psw ||| @z, else: psw
    psw = if (value &&& 0x8000) != 0, do: psw ||| @n, else: psw
    %{spc | psw: psw}
  end
end
