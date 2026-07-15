defmodule Beamicom.NES.APUTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.APU

  @moduledoc "APU channel output (spec §2, §12 step 10)."

  test "an enabled pulse channel produces an oscillating square wave" do
    apu =
      APU.new()
      # enable pulse 1, duty 50% + constant volume 15 + halt (stays on), period ~253.
      |> APU.write(0x4015, 0x01)
      |> APU.write(0x4000, 0xBF)
      |> APU.write(0x4002, 0xFD)
      |> APU.write(0x4003, 0x08)

    {samples, _} = apu |> APU.tick(100_000) |> APU.take_samples()

    # ~44.1kHz over ~56ms.
    assert length(samples) > 2000
    # A square wave: more than one distinct level, and it produces sound.
    assert length(Enum.uniq(samples)) > 1
    assert Enum.max(samples) > 0
  end

  test "a disabled/silent APU settles to silence (DC blocked by the output filter)" do
    {samples, _} = APU.new() |> APU.tick(50_000) |> APU.take_samples()
    # The triangle DAC holds a DC level even when silenced; the RCA high-pass
    # filter removes it, so the signal decays to a flat zero rather than sitting
    # at a constant offset.
    assert Enum.uniq(Enum.take(samples, -100)) == [0]
  end

  test "a playing triangle at an ultrasonic period (<2) stays silent, not squealing" do
    # Games write period 0 to silence the triangle: the frequency is ultrasonic
    # (>27kHz) and inaudible on hardware. Naively spinning the sequencer would
    # alias it down to an audible ~11.8kHz squeal, so it must be muted at source.
    apu =
      APU.new()
      # enable triangle, load a non-zero linear counter + length, period 0.
      |> APU.write(0x4015, 0x04)
      |> APU.write(0x4008, 0x7F)
      |> APU.write(0x400A, 0x00)
      |> APU.write(0x400B, 0x08)

    {samples, _} = apu |> APU.tick(50_000) |> APU.take_samples()
    # Sequencer frozen → constant output → high-pass decays it to flat silence.
    assert Enum.uniq(Enum.take(samples, -100)) == [0]
  end

  test "MMC5 sound: an enabled pulse mixes an oscillating wave into the output" do
    apu =
      APU.new()
      |> APU.mmc5_write(0x5015, 0x01)
      |> APU.mmc5_write(0x5000, 0xBF)
      |> APU.mmc5_write(0x5002, 0xFD)
      |> APU.mmc5_write(0x5003, 0x08)

    {samples, _} = apu |> APU.tick(100_000) |> APU.take_samples()
    assert length(Enum.uniq(samples)) > 1
    assert Enum.max(samples) > 0
  end

  test "MMC5 raw PCM ($5011) contributes a DC level to the mix" do
    quiet = APU.new() |> APU.tick(2_000) |> APU.take_samples() |> elem(0) |> Enum.max()

    loud =
      APU.new()
      |> APU.mmc5_write(0x5011, 0xFF)
      |> APU.tick(2_000)
      |> APU.take_samples()
      |> elem(0)
      |> Enum.max()

    assert loud > quiet
  end

  test "the frame counter asserts an IRQ in 4-step mode and $4015 read clears it" do
    # 4-step mode, IRQ enabled (bit 6 clear). Run past the end of a sequence.
    apu = APU.new() |> APU.write(0x4017, 0x00) |> APU.tick(30_000)
    assert APU.irq?(apu)

    {_status, apu} = APU.read_status(apu)
    refute APU.irq?(apu)
  end
end
