defmodule Beamicom.GBA.APUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.GBA.APU

  test "clocks signed FIFO samples and renders routed stereo PCM" do
    apu =
      APU.new()
      |> APU.put_register(0x82, 0x04, 0)
      |> APU.put_register(0x83, 0x03, 0)
      |> APU.put_register(0x84, 0x80, 0)
      |> APU.put_fifo(:a, 0x40)
      |> APU.put_fifo(:a, 0xC0)

    assert {apu, [:a, :b]} = APU.timer_overflow(apu, 0, 100)
    assert apu.sample_a == 64
    assert APU.fifo_size(apu, :a) == 1

    assert {apu, 20, pcm, 0} = APU.render(apu, 200, 0, 1_000, 100)
    assert byte_size(pcm) == 20 * 4

    assert <<_silence::binary-size(36), 8192::signed-little-16, 8192::signed-little-16,
             _::binary>> = pcm

    assert {apu, [:a, :b]} = APU.timer_overflow(apu, 0, 250)
    assert apu.sample_a == -64
  end

  test "FIFO reset bits clear queued samples and self-clear" do
    apu = APU.new() |> APU.put_fifo(:a, 1) |> APU.put_fifo(:b, 2)
    apu = APU.put_register(apu, 0x83, 0x88, 4)

    assert APU.fifo_size(apu, :a) == 0
    assert APU.fifo_size(apu, :b) == 0
    assert APU.register(apu, 0x83) == 0
  end

  test "packed FIFO writes preserve order and stop at hardware capacity" do
    samples = 1..34 |> Enum.to_list() |> :erlang.list_to_binary()

    apu =
      APU.new()
      |> APU.put_register(0x84, 0x80, 0)
      |> APU.put_fifo_binary(:a, samples)

    assert APU.fifo_size(apu, :a) == 32
    assert {apu, _refills} = APU.timer_overflow(apu, 0, 1)
    assert apu.sample_a == 1
    assert {apu, _refills} = APU.timer_overflow(apu, 0, 2)
    assert apu.sample_a == 2
  end

  test "renders both pulse channels with PSG volume and stereo routing" do
    apu =
      APU.new()
      |> APU.put_register(0x84, 0x80, 0)
      |> APU.put_register(0x80, 0x77, 0)
      |> APU.put_register(0x81, 0x33, 0)
      |> APU.put_register(0x82, 0x02, 0)
      |> APU.put_register(0x62, 0x80, 0)
      |> APU.put_register(0x63, 0xF0, 0)
      |> APU.put_register(0x64, 0x00, 0)
      |> APU.put_register(0x65, 0x87, 0)
      |> APU.put_register(0x68, 0x40, 0)
      |> APU.put_register(0x69, 0xA0, 0)
      |> APU.put_register(0x6C, 0x40, 0)
      |> APU.put_register(0x6D, 0x87, 0)

    assert (APU.register(apu, 0x84) &&& 0x03) == 0x03
    assert {apu, count, pcm, _phase} = APU.render(apu, 20_000, 0, 16_777_216, 44_100)
    assert byte_size(pcm) == count * 4
    assert non_silent?(pcm)
    assert (APU.register(apu, 0x84) &&& 0x03) == 0x03
  end

  test "renders banked wave and noise channels" do
    apu =
      APU.new()
      |> APU.put_register(0x84, 0x80, 0)
      |> APU.put_register(0x80, 0x77, 0)
      |> APU.put_register(0x81, 0xCC, 0)
      |> APU.put_register(0x82, 0x02, 0)
      # Bank zero is selected, so the CPU-visible window writes bank one.
      |> APU.put_register(0x70, 0x80, 0)
      |> write_wave(0xF0)
      |> APU.put_register(0x70, 0xC0, 0)
      |> APU.put_register(0x73, 0x20, 0)
      |> APU.put_register(0x74, 0x00, 0)
      |> APU.put_register(0x75, 0x87, 0)
      |> APU.put_register(0x79, 0xF0, 0)
      |> APU.put_register(0x7C, 0x01, 0)
      |> APU.put_register(0x7D, 0x80, 0)

    assert {apu, _count, pcm, _phase} = APU.render(apu, 30_000, 0, 16_777_216, 44_100)
    assert non_silent?(pcm)
    assert (APU.register(apu, 0x84) &&& 0x0C) == 0x0C
  end

  test "powering sound off clears PSG status and routing" do
    apu =
      APU.new()
      |> APU.put_register(0x84, 0x80, 0)
      |> APU.put_register(0x62, 0x80, 0)
      |> APU.put_register(0x63, 0xF0, 0)
      |> APU.put_register(0x65, 0x80, 0)
      |> APU.put_register(0x84, 0x00, 100)

    assert {apu, _count, pcm, _phase} = APU.render(apu, 1_000, 0, 16_777_216, 44_100)
    assert APU.register(apu, 0x84) == 0
    assert APU.register(apu, 0x80) == 0
    refute non_silent?(pcm)
  end

  defp write_wave(apu, byte) do
    Enum.reduce(0x90..0x9F, apu, fn offset, apu ->
      APU.put_register(apu, offset, byte, 0)
    end)
  end

  defp non_silent?(pcm) do
    Enum.any?(for(<<sample::signed-little-16 <- pcm>>, do: sample), &(&1 != 0))
  end
end
