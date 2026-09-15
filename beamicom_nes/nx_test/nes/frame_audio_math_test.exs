defmodule Beamicom.NES.Nx.FrameAudioMathTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameAudioMath

  test "phase accumulation uses cumulative_sum and wraps at one cycle" do
    phase =
      FrameAudioMath.phase(
        Nx.tensor([0.25, 0.25, 0.25, 0.25, 0.25], type: :f32),
        Nx.tensor(0.0, type: :f32)
      )

    assert_all_close(Nx.to_flat_list(phase), [0.25, 0.5, 0.75, 0.0, 0.25], 1.0e-6)
  end

  test "Nx.conv windowed sinc decimates 192 kHz to a fixed 48 kHz frame" do
    samples = Nx.broadcast(Nx.tensor(1.0, type: :f32), {3200})
    kernel = FrameAudioMath.sinc_kernel()
    args = [samples, kernel]
    compiled = Beamicom.NES.Nx.compile(&FrameAudioMath.decimate_4x/2, args)
    pcm = apply(compiled, args)

    assert Nx.shape(pcm) == {800}
    assert Nx.type(pcm) == {:s, 16}
    assert Nx.to_number(pcm[100]) == 32767
  end

  test "sinc low-pass suppresses a Nyquist-rate input before decimation" do
    samples = Nx.tensor(for(index <- 0..3199, do: if(rem(index, 2) == 0, do: 1.0, else: -1.0)))
    kernel = FrameAudioMath.sinc_kernel()
    args = [samples, kernel]
    pcm = Beamicom.NES.Nx.compile(&FrameAudioMath.decimate_4x/2, args) |> apply(args)

    assert abs(Nx.to_number(pcm[100])) < 100
  end

  defp assert_all_close(actual, expected, tolerance) do
    Enum.zip(actual, expected)
    |> Enum.each(fn {actual, expected} -> assert abs(actual - expected) <= tolerance end)
  end
end
