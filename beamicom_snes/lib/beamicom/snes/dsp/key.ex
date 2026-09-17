defmodule Beamicom.SNES.DSP.Key do
  @moduledoc """
  Two-sample KON/KOFF poll and latch state.

  KON writes replace the request latch. Phase 29 toggles the poll cadence and
  clears requests that survived the preceding poll; phase 30 transfers KON and
  KOFF into the voice-visible latches. The ordering follows the
  [ares misc stages](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/misc.cpp).
  """

  import Bitwise

  defstruct kon_latch: 0,
            key_on: 0,
            key_off_register: 0,
            key_off: 0,
            sample_poll?: true

  def new, do: %__MODULE__{}

  def write_kon(%__MODULE__{} = key, bits),
    do: %{key | kon_latch: bits &&& 0xFF}

  def write_koff(%__MODULE__{} = key, bits),
    do: %{key | key_off_register: bits &&& 0xFF}

  def phase29(%__MODULE__{} = key) do
    sample_poll? = not key.sample_poll?

    kon_latch =
      if sample_poll?,
        do: key.kon_latch &&& bnot(key.key_on),
        else: key.kon_latch

    %{key | sample_poll?: sample_poll?, kon_latch: kon_latch}
  end

  def phase30(%__MODULE__{sample_poll?: true} = key),
    do: %{key | key_on: key.kon_latch, key_off: key.key_off_register}

  def phase30(%__MODULE__{} = key), do: key

  def key_on?(%__MODULE__{} = key, index) when index in 0..7,
    do: (key.key_on &&& 1 <<< index) != 0

  def key_off?(%__MODULE__{} = key, index) when index in 0..7,
    do: (key.key_off &&& 1 <<< index) != 0

  def signals(%__MODULE__{} = key, index),
    do: {key_on?(key, index), key_off?(key, index)}
end
