defmodule Beamicom.SNES.DSP.Echo.State do
  @moduledoc """
  Serializable S-DSP echo history and ring-buffer state.

  History is the physical eight-slot hardware ring. `history_offset` identifies
  the slot most recently written by the echo RAM read.
  """

  @empty_history List.duplicate({0, 0}, 8) |> List.to_tuple()

  defstruct history: @empty_history,
            history_offset: 0,
            page: 0,
            offset: 0,
            length: 0,
            echo_input: {0, 0},
            feedback_output: {0, 0}

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    state = struct!(__MODULE__, opts)

    if is_tuple(state.history) and tuple_size(state.history) == 8 do
      state
    else
      raise ArgumentError, "echo history must be an eight-element tuple"
    end
  end
end
