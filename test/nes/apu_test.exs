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

  test "a disabled/silent APU produces a flat (constant) signal" do
    {samples, _} = APU.new() |> APU.tick(50_000) |> APU.take_samples()
    assert length(Enum.uniq(samples)) == 1
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
