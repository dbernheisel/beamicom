defmodule Beamicom.SNES.DSP.Mixer do
  @moduledoc """
  Saturating main-bus and final-volume operations for the scalar S-DSP.

  Voice stages feed one stereo contribution at a time to `accumulate/2`. Each
  call clamps immediately, preserving hardware ordering before master volume.
  A60 combines its independently saturated echo bus after its FIR/feedback
  stages; that extension does not change this function's inputs.
  """

  alias Beamicom.SNES.DSP.Arithmetic

  def accumulate({left, right}, {add_left, add_right}) do
    {Arithmetic.clamp16(left + add_left), Arithmetic.clamp16(right + add_right)}
  end

  def finalize(_main, _master, true), do: {0, 0}

  def finalize({left, right}, {master_left, master_right}, false) do
    {
      Arithmetic.clamp16(Arithmetic.shift_right(left * master_left, 7)),
      Arithmetic.clamp16(Arithmetic.shift_right(right * master_right, 7))
    }
  end
end
