defmodule Beamicom.SNES.DSP.Clock do
  @moduledoc """
  Clock/latch state for the scalar 32-phase S-DSP pipeline.

  Phase 0 snapshots the visible register file and key latches. Phases 1 through
  30 are stable extension points for the phase-accurate A40 voice and A50
  noise/modulation work. Phase 31 commits voice state, A60 echo state, and one
  stereo sample through the final mixer.

  `registers` and `mixer` are immutable sample-local inputs. Later feature
  stages must return updated clock or pipeline structs rather than mutate DSP
  registers behind the shared A30 timeline.
  """

  alias Beamicom.SNES.DSP.{Noise, Pipeline, VoicePipeline}
  alias Beamicom.SNES.DSP.Echo.State, as: EchoState

  @empty_registers List.duplicate(0, 128) |> List.to_tuple()

  defstruct phase: 0,
            sample_counter: 0,
            registers: @empty_registers,
            mixer: nil,
            pipeline: %Pipeline{},
            voice_pipeline: VoicePipeline.new(),
            noise: %Noise{},
            echo_state: %EchoState{},
            echo_left_read: nil,
            echo_right_read: nil,
            echo_pending_state: nil,
            echo_write_effects: [],
            echo_pcm: nil,
            echo_flg_28: 0,
            echo_flg_29: 0

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def latch(%__MODULE__{phase: 0} = clock, registers, mixer) do
    %{clock | registers: registers, mixer: mixer}
  end

  def advance(%__MODULE__{phase: phase} = clock) when phase in 0..30,
    do: %{clock | phase: phase + 1}

  def finish_sample(%__MODULE__{phase: 31} = clock, %Pipeline{} = pipeline) do
    finish(clock, pipeline)
  end

  def finish_aligned_sample(%__MODULE__{phase: 0} = clock, %Pipeline{} = pipeline),
    do: finish(clock, pipeline)

  def finish_block(%__MODULE__{phase: 0} = clock, registers, samples)
      when is_integer(samples) and samples >= 0 do
    %{
      clock
      | sample_counter: clock.sample_counter + samples,
        registers: registers,
        mixer: nil
    }
  end

  def read_latch(%__MODULE__{} = clock, address),
    do: elem(clock.registers, Bitwise.band(address, 0x7F))

  defp finish(clock, pipeline) do
    %{
      clock
      | phase: 0,
        sample_counter: clock.sample_counter + 1,
        mixer: nil,
        pipeline: pipeline,
        echo_left_read: nil,
        echo_right_read: nil,
        echo_pending_state: nil,
        echo_write_effects: [],
        echo_pcm: nil
    }
  end
end
