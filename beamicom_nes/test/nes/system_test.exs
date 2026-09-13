defmodule Beamicom.NES.SystemTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities, VideoFrame}
  alias Beamicom.NES.{Controllers, System}

  test "advertises system-neutral capabilities" do
    capabilities = System.capabilities()

    assert System.id() == :nes
    assert capabilities.video.width == 256
    assert capabilities.video.height == 240
    assert capabilities.audio == %{sample_rate: 44_100, channels: 1, sample_format: :s16le}
    assert InputCapabilities.accepts?(capabilities.input, Input.new(1, [:a, :start]))
    refute InputCapabilities.accepts?(capabilities.input, Input.new(3, [:a]))
  end

  test "loads media, applies input, and advances to typed output" do
    assert {:ok, console} = System.load(minimal_rom(), [])
    console = System.set_input(console, Input.new(1, [:a, :right]))

    assert console.bus.pad1.buttons == Controllers.mask([:a, :right])

    assert {console, [%VideoFrame{} = video, %AudioChunk{} = audio]} =
             System.run_slice(console)

    assert video.system == :nes
    assert video.width == 256
    assert video.height == 240
    assert video.pixel_format == {:native, :nes_framebuffer}
    assert video.data == console.bus.ppu.frame_ready
    assert audio.system == :nes
    assert audio.sample_rate == 44_100
    assert audio.channels == 1
    assert byte_size(audio.data) == audio.frame_count * 2
  end

  test "rejects invalid media" do
    assert {:error, :invalid_ines} = System.load("not a rom", [])
  end

  defp minimal_rom do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, 1, 0::size(10 * 8)>> <> prg <> <<0::size(8192 * 8)>>
  end
end
