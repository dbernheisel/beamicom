defmodule Beamicom.GBA.CPU.ALU do
  @moduledoc false

  import Bitwise

  @mask 0xFFFF_FFFF
  @sign 0x8000_0000
  @n @sign
  @z 0x4000_0000
  @c 0x2000_0000
  @v 0x1000_0000
  @nz @n ||| @z
  @nzc @nz ||| @c
  @nzcv @nzc ||| @v

  @compile {:inline, carry?: 1, flag?: 2, bit?: 2}

  def condition_passed?(0x0, cpsr), do: flag?(cpsr, @z)
  def condition_passed?(0x1, cpsr), do: not flag?(cpsr, @z)
  def condition_passed?(0x2, cpsr), do: flag?(cpsr, @c)
  def condition_passed?(0x3, cpsr), do: not flag?(cpsr, @c)
  def condition_passed?(0x4, cpsr), do: flag?(cpsr, @n)
  def condition_passed?(0x5, cpsr), do: not flag?(cpsr, @n)
  def condition_passed?(0x6, cpsr), do: flag?(cpsr, @v)
  def condition_passed?(0x7, cpsr), do: not flag?(cpsr, @v)
  def condition_passed?(0x8, cpsr), do: flag?(cpsr, @c) and not flag?(cpsr, @z)
  def condition_passed?(0x9, cpsr), do: not flag?(cpsr, @c) or flag?(cpsr, @z)
  def condition_passed?(0xA, cpsr), do: flag?(cpsr, @n) == flag?(cpsr, @v)
  def condition_passed?(0xB, cpsr), do: flag?(cpsr, @n) != flag?(cpsr, @v)

  def condition_passed?(0xC, cpsr),
    do: not flag?(cpsr, @z) and flag?(cpsr, @n) == flag?(cpsr, @v)

  def condition_passed?(0xD, cpsr),
    do: flag?(cpsr, @z) or flag?(cpsr, @n) != flag?(cpsr, @v)

  def condition_passed?(0xE, _cpsr), do: true
  def condition_passed?(0xF, _cpsr), do: false

  def carry?(cpsr), do: flag?(cpsr, @c)

  def add(left, right, carry \\ 0) do
    unsigned = (left &&& @mask) + (right &&& @mask) + carry
    result = unsigned &&& @mask
    overflow = (bnot(bxor(left, right)) &&& bxor(left, result) &&& @sign) != 0
    {result, unsigned > @mask, overflow}
  end

  def subtract(left, right, borrow \\ 0) do
    subtrahend = (right &&& @mask) + borrow
    result = left - subtrahend &&& @mask
    overflow = (bxor(left, right) &&& bxor(left, result) &&& @sign) != 0
    {result, (left &&& @mask) >= subtrahend, overflow}
  end

  def put_nz(cpsr, result) do
    flags =
      if((result &&& @sign) != 0, do: @n, else: 0) |||
        if((result &&& @mask) == 0, do: @z, else: 0)

    (cpsr &&& bnot(@nz)) ||| flags
  end

  def put_nzc(cpsr, result, carry) do
    flags =
      if((result &&& @sign) != 0, do: @n, else: 0) |||
        if((result &&& @mask) == 0, do: @z, else: 0) |||
        if(carry, do: @c, else: 0)

    (cpsr &&& bnot(@nzc)) ||| flags
  end

  def put_nzcv(cpsr, result, carry, overflow) do
    flags =
      if((result &&& @sign) != 0, do: @n, else: 0) |||
        if((result &&& @mask) == 0, do: @z, else: 0) |||
        if(carry, do: @c, else: 0) |||
        if(overflow, do: @v, else: 0)

    (cpsr &&& bnot(@nzcv)) ||| flags
  end

  def shift_immediate(value, 0, 0, carry), do: {value &&& @mask, carry}

  def shift_immediate(value, 0, amount, _carry) do
    {value <<< amount &&& @mask, bit?(value, 32 - amount)}
  end

  def shift_immediate(value, 1, 0, _carry), do: {0, bit?(value, 31)}

  def shift_immediate(value, 1, amount, _carry) do
    {value >>> amount, bit?(value, amount - 1)}
  end

  def shift_immediate(value, 2, 0, _carry), do: arithmetic_right(value, 32)
  def shift_immediate(value, 2, amount, _carry), do: arithmetic_right(value, amount)

  def shift_immediate(value, 3, 0, carry) do
    result = (if(carry, do: @sign, else: 0) ||| value >>> 1) &&& @mask
    {result, bit?(value, 0)}
  end

  def shift_immediate(value, 3, amount, _carry), do: rotate_right(value, amount)

  def shift_register(value, _type, 0, carry), do: {value &&& @mask, carry}

  def shift_register(value, 0, amount, _carry) when amount < 32,
    do: {value <<< amount &&& @mask, bit?(value, 32 - amount)}

  def shift_register(value, 0, 32, _carry), do: {0, bit?(value, 0)}
  def shift_register(_value, 0, _amount, _carry), do: {0, false}

  def shift_register(value, 1, amount, _carry) when amount < 32,
    do: {value >>> amount, bit?(value, amount - 1)}

  def shift_register(value, 1, 32, _carry), do: {0, bit?(value, 31)}
  def shift_register(_value, 1, _amount, _carry), do: {0, false}

  def shift_register(value, 2, amount, _carry) when amount < 32,
    do: arithmetic_right(value, amount)

  def shift_register(value, 2, _amount, _carry), do: arithmetic_right(value, 32)

  def shift_register(value, 3, amount, _carry) do
    case rem(amount, 32) do
      0 -> {value &&& @mask, bit?(value, 31)}
      rotation -> rotate_right(value, rotation)
    end
  end

  def rotate_immediate(value, 0, carry), do: {value &&& 0xFF, carry}
  def rotate_immediate(value, rotation, _carry), do: rotate_right(value, rotation * 2)

  def sign_extend(value, bits) do
    sign = 1 <<< (bits - 1)
    value = value &&& (1 <<< bits) - 1
    if (value &&& sign) == 0, do: value, else: value - (1 <<< bits)
  end

  defp arithmetic_right(value, amount) do
    if bit?(value, 31) do
      shift = min(amount, 32)
      fill = @mask <<< (32 - shift) &&& @mask
      {(value >>> shift ||| fill) &&& @mask, true}
    else
      {value >>> min(amount, 32), false}
    end
  end

  defp rotate_right(value, amount) do
    amount = rem(amount, 32)
    result = (value >>> amount ||| value <<< (32 - amount)) &&& @mask
    {result, bit?(result, 31)}
  end

  defp flag?(value, flag), do: (value &&& flag) != 0
  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
