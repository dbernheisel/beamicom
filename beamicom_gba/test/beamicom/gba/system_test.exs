defmodule Beamicom.GBA.SystemTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.{Bus, System, TestROM}
  alias Beamicom.GBA.PPU.ColorCorrection
  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities, VideoFrame}

  test "advertises the diagnostic GBA host contract" do
    capabilities = System.capabilities()

    assert System.id() == :gba
    assert capabilities.media_extensions == [".gba"]
    assert capabilities.video.width == 240
    assert capabilities.video.height == 160
    assert capabilities.video.pixel_formats == [:rgb24]
    assert_in_delta capabilities.video.frame_rate, 59.7275, 0.0001
    assert capabilities.audio == %{sample_rate: 44_100, channels: 2, sample_format: :s16le}
    assert capabilities.maturity == :diagnostic
    assert InputCapabilities.accepts?(capabilities.input, Input.new(1, [:a, :l, :start]))
    refute InputCapabilities.accepts?(capabilities.input, Input.new(2, [:a]))
  end

  test "emits one RGB24 frame and deterministic stereo audio chunk" do
    assert {:ok, machine} = System.load(TestROM.build())
    {bus, 1} = Bus.write16(machine.bus, 0x0400_0000, 0x0403)
    {bus, 1} = Bus.write16(bus, 0x0600_0000, 0x7C00)
    machine = System.set_input(%{machine | bus: bus}, Input.new(1, [:a, :left]))

    assert {machine, [%VideoFrame{} = video, %AudioChunk{} = audio]} =
             System.run_slice(machine)

    assert video.system == :gba
    assert video.number == 0
    assert {video.width, video.height, video.pixel_format} == {240, 160, :rgb24}
    assert binary_part(video.data, 0, 3) == ColorCorrection.rgb24(0x7C00)
    assert byte_size(video.data) == 240 * 160 * 3
    assert video.metadata == %{maturity: :diagnostic}
    assert audio.system == :gba
    assert {audio.sample_rate, audio.channels, audio.sample_format} == {44_100, 2, :s16le}
    assert audio.frame_count == 738
    assert byte_size(audio.data) == 738 * 4
    assert Bus.peek16(machine.bus, 0x0400_0130) == 0x03DE
  end
end
