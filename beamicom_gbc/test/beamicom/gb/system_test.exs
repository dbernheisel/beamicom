defmodule Beamicom.GB.SystemTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Beamicom.GB.{DiagnosticROM, System}
  alias Beamicom.Host.{Input, InputCapabilities, VideoFrame}

  test "advertises one handheld input port and native shade-index video" do
    capabilities = System.capabilities()

    assert System.id() == :gbc
    assert capabilities.video.width == 160
    assert capabilities.video.height == 144

    assert capabilities.video.pixel_formats == [
             {:native, :dmg_shade_index},
             :rgb24
           ]

    assert capabilities.audio == nil
    assert InputCapabilities.accepts?(capabilities.input, Input.new(1, [:a, :start]))
    refute InputCapabilities.accepts?(capabilities.input, Input.new(2, [:a]))
  end

  test "loads media, replaces input, and emits one coarse video frame" do
    assert {:ok, machine} = System.load(rom(), [])
    machine = System.set_input(machine, Input.new(1, [:right, :a, :start]))
    assert machine.bus.buttons == 0x91

    assert {machine, [%VideoFrame{} = video]} = System.run_slice(machine)
    assert video.system == :gbc
    assert video.number == 0
    assert {video.width, video.height} == {160, 144}
    assert video.pixel_format == {:native, :dmg_shade_index}
    assert byte_size(video.data) == 160 * 144
    assert video.data == machine.bus.ppu.frame
    assert video.metadata == %{model: :dmg}
    assert video.duration_ns == round(456 * 154 * 1_000_000_000 / 4_194_304)
  end

  test "rejects invalid media" do
    assert {:error, {:rom_too_small, 0x150, 9}} = System.load("not a rom", [])
  end

  test "emits CGB frames as native RGB24" do
    assert {:ok, machine} = System.load(DiagnosticROM.build_cgb(), [])
    assert {machine, [%VideoFrame{} = video]} = System.run_slice(machine)
    assert machine.model == :cgb
    assert video.pixel_format == :rgb24
    assert byte_size(video.data) == 160 * 144 * 3
    assert video.metadata == %{model: :cgb}
  end

  defp rom do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0xC3, 0x50, 0x01>>)
    |> put_bytes(0x134, "SYSTEM TEST" <> :binary.copy(<<0>>, 5))
    |> put_byte(0x143, 0)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> put_bytes(0x150, <<0x18, 0xFE>>)
    |> with_checksum()
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
