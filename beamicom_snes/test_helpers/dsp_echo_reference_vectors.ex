defmodule Beamicom.SNES.DSPEchoReferenceVectors do
  @moduledoc "Original, data-only S-DSP echo vectors derived from documented hardware arithmetic."

  def eight_tap_impulse do
    %{
      history: {
        {70, -70},
        {0, 0},
        {10, -10},
        {20, -20},
        {30, -30},
        {40, -40},
        {50, -50},
        {60, -60}
      },
      ram_sample: {160, -160},
      coefficients: List.duplicate(64, 8),
      filtered: {360, -360}
    }
  end

  def clipped_fir do
    %{
      history: List.duplicate({16_383, -16_384}, 8) |> List.to_tuple(),
      ram_sample: {32_766, -32_768},
      coefficients: List.duplicate(127, 8),
      filtered: {32_766, -32_768}
    }
  end

  def registers(entries \\ []) do
    Enum.reduce(entries, List.duplicate(0, 128) |> List.to_tuple(), fn {address, value},
                                                                       registers ->
      put_elem(registers, register_address(address), value)
    end)
  end

  def with_fir(registers, coefficients) do
    coefficients
    |> Enum.with_index()
    |> Enum.reduce(registers, fn {coefficient, index}, registers ->
      put_elem(registers, 0x0F + index * 0x10, coefficient)
    end)
  end

  defp register_address(:mvoll), do: 0x0C
  defp register_address(:mvolr), do: 0x1C
  defp register_address(:evoll), do: 0x2C
  defp register_address(:evolr), do: 0x3C
  defp register_address(:efb), do: 0x0D
  defp register_address(:eon), do: 0x4D
  defp register_address(:flg), do: 0x6C
  defp register_address(:esa), do: 0x6D
  defp register_address(:edl), do: 0x7D
  defp register_address(address) when is_integer(address), do: address
end
