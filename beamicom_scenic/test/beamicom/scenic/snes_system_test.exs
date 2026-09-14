defmodule Beamicom.Scenic.SNESSystemTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.Host.{AudioChunk, Input, VideoFrame}
  alias Beamicom.Scenic.SNESSystem

  test "adapts an SNES frame and audio slice to the shared host contracts" do
    assert {:ok, state} = SNESSystem.load(rom(<<0x80, 0xFE>>))
    assert {state, [%VideoFrame{} = video, %AudioChunk{} = audio]} = SNESSystem.run_slice(state)

    assert video.system == :snes
    assert {video.width, video.height, video.pixel_format} == {256, 224, :rgb24}
    assert byte_size(video.data) == 256 * 224 * 3
    assert audio.system == :snes
    assert audio.sample_rate == 32_000
    assert audio.channels == 2
    assert audio.sample_format == :s16le
    assert audio.frame_count > 0
    assert byte_size(audio.data) == audio.frame_count * 4
    assert state.halted == nil
  end

  test "freezes unsupported work while retaining an inspectable video surface" do
    assert {:ok, state} = SNESSystem.load(rom(<<0x02>>))
    assert {halted, [%VideoFrame{} = first]} = SNESSystem.run_slice(state)
    refute is_nil(halted.halted)

    assert {halted, [%VideoFrame{} = second]} = SNESSystem.run_slice(halted)
    assert second.number == first.number + 1
    assert SNESSystem.set_input(halted, Input.new(1, [:a])) == halted
  end

  defp rom(program) do
    size = 0x10000
    header = 0x7FC0

    rom =
      :binary.copy(<<0>>, size)
      |> put_bytes(header, "BEAMICOM SCENIC SNES" <> <<0x20>>)
      |> put_byte(header + 0x15, 0x20)
      |> put_byte(header + 0x17, 6)
      |> put_byte(header + 0x19, 1)
      |> put_byte(header + 0x1A, 0x33)
      |> put_bytes(header + 0x3C, <<0x00, 0x80>>)
      |> put_bytes(0, program)

    checksum = Beamicom.SNES.Cartridge.checksum(rom) + 510 &&& 0xFFFF
    complement = bxor(checksum, 0xFFFF)

    rom
    |> put_bytes(header + 0x1C, <<complement &&& 0xFF, complement >>> 8>>)
    |> put_bytes(header + 0x1E, <<checksum &&& 0xFF, checksum >>> 8>>)
  end

  defp put_byte(binary, offset, byte), do: put_bytes(binary, offset, <<byte>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
