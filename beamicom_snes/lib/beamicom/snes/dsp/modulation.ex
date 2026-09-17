defmodule Beamicom.SNES.DSP.Modulation do
  @moduledoc """
  S-DSP pitch modulation using the preceding voice's signed output.

  PMON can affect voices 1 through 7. Voice zero and disabled PMON bits preserve
  the base pitch. Active modulation expands the 14-bit base pitch into the
  hardware's 15-bit pitch range.
  """

  import Bitwise

  alias Beamicom.SNES.DSP.{Arithmetic, Pipeline}

  def pitch(base_pitch, _voice_index, %Pipeline{}), do: base_pitch

  def pitch(base_pitch, 0, _pmon, %Pipeline{}), do: base_pitch

  def pitch(base_pitch, voice_index, pmon, %Pipeline{} = pipeline)
      when voice_index in 1..7 and is_integer(pmon) do
    if (pmon &&& 1 <<< voice_index) != 0 do
      previous_output = Pipeline.previous_voice_output(pipeline, voice_index)
      modulated_pitch(base_pitch, previous_output)
    else
      base_pitch
    end
  end

  def modulated_pitch(base_pitch, previous_output)
      when is_integer(base_pitch) and is_integer(previous_output) do
    base_pitch = base_pitch &&& 0x3FFF
    previous_output = Arithmetic.signed16(previous_output)
    scale = Arithmetic.shift_right(previous_output, 5)
    delta = Arithmetic.shift_right(scale * base_pitch, 10)

    min(max(base_pitch + delta, 0), 0x7FFF)
  end
end
