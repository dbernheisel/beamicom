defmodule Beamicom.GB.APU.HighPass do
  @moduledoc """
  Models the analog high-pass capacitors on the Game Boy stereo output.

  A capacitor is connected whenever at least one channel DAC is enabled. Its
  charge is retained while every DAC is disabled, matching the behavior
  documented for DMG and CGB hardware in the Pan Docs audio details:
  https://gbdev.io/pandocs/Audio_details.html#high-pass-filter
  """

  @clock_rate 4_194_304
  @sample_rate 44_100
  @dmg_factor :math.pow(0.999958, @clock_rate / @sample_rate)
  @cgb_factor :math.pow(0.998943, @clock_rate / @sample_rate)
  @silence <<0::little-signed-16, 0::little-signed-16>>

  @type capacitor :: {float(), float()}

  @spec filter(binary(), binary(), :dmg | :cgb, capacitor()) :: {binary(), capacitor()}
  def filter(pcm, dac_samples, model, capacitor)
      when is_binary(pcm) and is_binary(dac_samples) and model in [:dmg, :cgb] do
    factor = if model == :cgb, do: @cgb_factor, else: @dmg_factor
    filter_samples(pcm, dac_samples, factor, capacitor, [])
  end

  defp filter_samples(<<>>, <<>>, _factor, capacitor, output),
    do: {output |> :lists.reverse() |> IO.iodata_to_binary(), capacitor}

  defp filter_samples(
         <<left::little-signed-16, right::little-signed-16, rest::binary>>,
         <<1, dac_rest::binary>>,
         factor,
         {left_capacitor, right_capacitor},
         output
       ) do
    left_output = left - left_capacitor
    right_output = right - right_capacitor

    capacitor = {
      left - left_output * factor,
      right - right_output * factor
    }

    sample =
      <<clamp(round(left_output))::little-signed-16,
        clamp(round(right_output))::little-signed-16>>

    filter_samples(rest, dac_rest, factor, capacitor, [sample | output])
  end

  defp filter_samples(
         <<_left::little-signed-16, _right::little-signed-16, rest::binary>>,
         <<0, dac_rest::binary>>,
         factor,
         capacitor,
         output
       ),
       do: filter_samples(rest, dac_rest, factor, capacitor, [@silence | output])

  defp filter_samples(_pcm, _dac_samples, _factor, _capacitor, _output),
    do: raise(ArgumentError, "PCM and DAC sample counts must match")

  defp clamp(value) when value > 32_767, do: 32_767
  defp clamp(value) when value < -32_768, do: -32_768
  defp clamp(value), do: value
end
