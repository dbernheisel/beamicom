defmodule Beamicom.SNES.DSP.Arithmetic do
  @moduledoc """
  Integer arithmetic shared by the scalar S-DSP pipeline stages.

  Values remain signed Elixir integers between explicit hardware boundaries.
  Callers choose `wrap_signed/2` for register-width wraparound or `clamp16/1`
  for the saturating S-DSP audio buses.
  """

  import Bitwise

  @compile {:inline, shift_right: 2, wrap_signed: 2, signed8: 1, signed16: 1, clamp16: 1}

  def shift_right(value, bits)
      when is_integer(value) and is_integer(bits) and bits >= 0,
      do: value >>> bits

  def wrap_signed(value, bits)
      when is_integer(value) and is_integer(bits) and bits > 0 do
    modulus = 1 <<< bits
    sign = 1 <<< (bits - 1)
    wrapped = value &&& modulus - 1
    if wrapped >= sign, do: wrapped - modulus, else: wrapped
  end

  def signed8(value), do: wrap_signed(value, 8)
  def signed16(value), do: wrap_signed(value, 16)
  def clamp16(value), do: min(max(value, -32_768), 32_767)
end
