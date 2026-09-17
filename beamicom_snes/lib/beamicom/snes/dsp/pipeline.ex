defmodule Beamicom.SNES.DSP.Pipeline do
  @moduledoc """
  Immutable per-sample interchange state for S-DSP feature stages.

  A40 records each voice's signed output with `record_voice/3`. A50 may use the
  preceding output for pitch modulation without reaching into voice internals.
  A60 owns `echo_bus`; it may accumulate echo-send values while leaving
  `main_bus` untouched. The final mixer consumes both buses after voice 7.
  """

  import Bitwise

  @voice_outputs List.duplicate(0, 8) |> List.to_tuple()

  defstruct voice_outputs: @voice_outputs,
            completed_voices: 0,
            main_bus: {0, 0},
            echo_bus: {0, 0},
            output: {0, 0}

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def begin_sample(%__MODULE__{} = pipeline) do
    %{
      pipeline
      | voice_outputs: @voice_outputs,
        completed_voices: 0,
        main_bus: {0, 0},
        echo_bus: {0, 0},
        output: {0, 0}
    }
  end

  def record_voice(%__MODULE__{} = pipeline, index, sample) when index in 0..7 do
    %{
      pipeline
      | voice_outputs: put_elem(pipeline.voice_outputs, index, sample),
        completed_voices: pipeline.completed_voices ||| 1 <<< index
    }
  end

  def previous_voice_output(%__MODULE__{}, 0), do: 0

  def previous_voice_output(%__MODULE__{} = pipeline, index) when index in 1..7,
    do: elem(pipeline.voice_outputs, index - 1)
end
