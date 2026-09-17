defmodule Beamicom.SNES.DSP.LiveRegisters do
  @moduledoc """
  Pipeline latches for ENDX, ENVX, and OUTX.

  ENVX and OUTX share one latch of each kind across all voices: voice stages 6
  and 7 capture values, while stages 8 and 9 publish them. Consequently, a CPU
  write between capture and publish can become the published value. ENDX keeps
  separate internal and published bits. This models the ordering documented by
  the [ares voice stages](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/voice.cpp).
  """

  import Bitwise

  @zeros List.duplicate(0, 8) |> List.to_tuple()

  defstruct envx: @zeros,
            outx: @zeros,
            envx_latch: 0,
            outx_latch: 0,
            end_flags: 0,
            published_endx: 0

  def new, do: %__MODULE__{}

  def read(%__MODULE__{} = live, 0x7C), do: live.published_endx

  def read(%__MODULE__{} = live, address) when (address &&& 0x0F) == 0x08,
    do: elem(live.envx, address >>> 4 &&& 0x07)

  def read(%__MODULE__{} = live, address) when (address &&& 0x0F) == 0x09,
    do: elem(live.outx, address >>> 4 &&& 0x07)

  def read(%__MODULE__{}, _address), do: 0

  def write(%__MODULE__{} = live, 0x7C, _value), do: clear_endx(live)

  def write(%__MODULE__{} = live, address, value) when (address &&& 0x0F) == 0x08 do
    index = address >>> 4 &&& 0x07
    value = value &&& 0xFF
    %{live | envx: put_elem(live.envx, index, value), envx_latch: value}
  end

  def write(%__MODULE__{} = live, address, value) when (address &&& 0x0F) == 0x09 do
    index = address >>> 4 &&& 0x07
    value = value &&& 0xFF
    %{live | outx: put_elem(live.outx, index, value), outx_latch: value}
  end

  def write(%__MODULE__{} = live, _address, _value), do: live

  def capture_outx(%__MODULE__{} = live, output),
    do: %{live | outx_latch: output >>> 8 &&& 0xFF}

  def capture_envx(%__MODULE__{} = live, envelope),
    do: %{live | envx_latch: envelope >>> 4 &&& 0xFF}

  def capture_envx_value(%__MODULE__{} = live, envx),
    do: %{live | envx_latch: envx &&& 0xFF}

  def publish_outx(%__MODULE__{} = live, index) when index in 0..7,
    do: %{live | outx: put_elem(live.outx, index, live.outx_latch)}

  def publish_envx(%__MODULE__{} = live, index) when index in 0..7,
    do: %{live | envx: put_elem(live.envx, index, live.envx_latch)}

  def record_end(%__MODULE__{} = live, _index, false), do: live

  def record_end(%__MODULE__{} = live, index, true) when index in 0..7,
    do: %{live | end_flags: live.end_flags ||| 1 <<< index}

  def clear_voice_end(%__MODULE__{} = live, index) when index in 0..7,
    do: %{live | end_flags: live.end_flags &&& bnot(1 <<< index)}

  def clear_endx(%__MODULE__{} = live),
    do: %{live | end_flags: 0, published_endx: 0}

  def publish_endx(%__MODULE__{} = live), do: %{live | published_endx: live.end_flags}
  def end_flags(%__MODULE__{} = live), do: live.end_flags
end
