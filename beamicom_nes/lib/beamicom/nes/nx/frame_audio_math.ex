if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameAudioMath do
    @moduledoc """
    Data-parallel phase accumulation and windowed-sinc decimation primitives.

    These are kept independent so the 48 kHz audio contract can be tested before
    it is composed with the live APU/DMC control state.
    """

    import Nx.Defn

    @doc "Accumulate per-sample phase increments and wrap the result to [0, 1)."
    defn phase(increments, initial_phase) do
      Nx.remainder(initial_phase + Nx.cumulative_sum(increments), 1.0)
    end

    @doc "Decimate one 192 kHz, 1/60-second block to 800 signed 48 kHz samples."
    defn decimate_4x(samples, kernel) do
      samples
      |> Nx.reshape({1, 1, 3200})
      |> Nx.conv(kernel, strides: [4], padding: [{16, 16}])
      |> Nx.reshape({800})
      |> Nx.multiply(32767.0)
      |> Nx.round()
      |> Nx.clip(-32768, 32767)
      |> Nx.as_type(:s16)
    end

    @doc "Build a normalized odd-width Hann-windowed low-pass sinc kernel."
    def sinc_kernel(taps \\ 33) when is_integer(taps) and taps > 1 and rem(taps, 2) == 1 do
      center = div(taps - 1, 2)
      cutoff = 1.0 / 8.0

      weights =
        for index <- 0..(taps - 1) do
          x = index - center

          sinc =
            if x == 0,
              do: 2.0 * cutoff,
              else: :math.sin(2.0 * :math.pi() * cutoff * x) / (:math.pi() * x)

          window = 0.5 - 0.5 * :math.cos(2.0 * :math.pi() * index / (taps - 1))
          sinc * window
        end

      total = Enum.sum(weights)

      weights
      |> Enum.map(&(&1 / total))
      |> Nx.tensor(type: :f32)
      |> Nx.reshape({1, 1, taps})
    end
  end
end
