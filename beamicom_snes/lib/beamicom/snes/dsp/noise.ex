defmodule Beamicom.SNES.DSP.Noise do
  @moduledoc """
  Immutable state and source selection for the S-DSP noise generator.

  The generator is a 15-bit LFSR seeded to `0x4000`. `clock/3` accepts the
  already-advanced shared DSP counter so noise remains aligned with envelope
  events. The low five FLG bits select one of the 32 hardware rates.
  """

  import Bitwise

  alias Beamicom.SNES.DSP.Arithmetic

  @counter_range 30_720
  @rates {
    0,
    2048,
    1536,
    1280,
    1024,
    768,
    640,
    512,
    384,
    320,
    256,
    192,
    160,
    128,
    96,
    80,
    64,
    48,
    40,
    32,
    24,
    20,
    16,
    12,
    10,
    8,
    6,
    5,
    4,
    3,
    2,
    1
  }
  @offsets {
    0,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    536,
    0,
    1040,
    0,
    0
  }

  defstruct lfsr: 0x4000, counter: 0, sample: 0

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def reset(%__MODULE__{}), do: new()

  def sample(%__MODULE__{lfsr: lfsr}), do: sample_from_lfsr(lfsr)

  def clock(%__MODULE__{} = noise, flg, counter)
      when is_integer(flg) and is_integer(counter) do
    counter = Integer.mod(counter, @counter_range)
    rate = flg &&& 0x1F

    lfsr =
      if tick?(rate, counter) do
        next_lfsr(noise.lfsr)
      else
        noise.lfsr
      end

    %{noise | lfsr: lfsr, counter: counter, sample: sample_from_lfsr(lfsr)}
  end

  def next_lfsr(lfsr) when is_integer(lfsr) do
    lfsr = lfsr &&& 0x7FFF
    feedback = bxor(lfsr <<< 13, lfsr <<< 14) &&& 0x4000
    feedback ||| lfsr >>> 1
  end

  def sample_from_lfsr(lfsr) when is_integer(lfsr) do
    Arithmetic.signed16((lfsr &&& 0x7FFF) <<< 1)
  end

  def select_source(decoded_sample, noise_sample, non, voice_index)
      when is_integer(decoded_sample) and is_integer(noise_sample) and
             is_integer(non) and voice_index in 0..7 do
    if (non &&& 1 <<< voice_index) != 0, do: noise_sample, else: decoded_sample
  end

  defp tick?(0, _counter), do: false

  defp tick?(rate, counter) do
    Integer.mod(counter + elem(@offsets, rate), elem(@rates, rate)) == 0
  end
end
