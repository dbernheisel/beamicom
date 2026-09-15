defmodule Beamicom.Scenic.RuntimeTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.GB.System
  alias Beamicom.Host.{Input, Output, VideoFrame}
  alias Beamicom.Scenic.Runtime

  defmodule TenFpsSystem do
    alias Beamicom.Host.{Input, VideoFrame}

    def capabilities do
      %{
        video: %{width: 1, height: 1, frame_rate: 10.0},
        audio: %{sample_rate: 44_100, channels: 1, sample_format: :s16le}
      }
    end

    def run_slice(number) do
      frame = %VideoFrame{
        system: :timer_test,
        number: number,
        width: 1,
        height: 1,
        pixel_format: :rgb24,
        data: <<0, 0, 0>>
      }

      {number + 1, [frame]}
    end

    def set_input(machine, %Input{}), do: machine
  end

  test "publishes a Game Boy frame and accepts handheld input" do
    output = start_supervised!({Output, name: nil})
    :ok = Output.subscribe_video(output)
    {:ok, machine} = System.load(rom())

    runtime =
      start_supervised!({Runtime, system: System, machine: machine, output: output, speed: 0.01})

    assert_receive {:video_frame, :gbc, 0}, 2_000
    assert %VideoFrame{width: 160, height: 144} = Output.latest_video(output)

    :ok = Runtime.set_input(runtime, Input.new(1, [:a, :right]))
    :ok = Runtime.pause(runtime)
    state = :sys.get_state(runtime)
    assert state.machine.bus.buttons == 0x11
    assert state.paused

    :ok = Runtime.step(runtime)
    assert_receive {:video_frame, :gbc, 1}, 2_000
    assert %VideoFrame{number: 1} = Output.latest_video(output)
  end

  test "pause and resume cannot leave a second pacing timer chain" do
    output = start_supervised!({Output, name: nil})
    :ok = Output.subscribe_video(output)

    runtime =
      start_supervised!(
        {Runtime, system: TenFpsSystem, machine: 0, output: output, pace: true, speed: 1.0}
      )

    assert_receive {:video_frame, :timer_test, 0}, to_timeout(millisecond: 200)
    assert %VideoFrame{number: 0} = Output.latest_video(output)

    generation = :sys.get_state(runtime).generation
    Runtime.pause(runtime)
    assert %{paused: true, generation: paused_generation} = :sys.get_state(runtime)
    assert paused_generation > generation

    Runtime.resume(runtime)

    assert_receive {:video_frame, :timer_test, 1}, to_timeout(millisecond: 100)
    assert %VideoFrame{number: 1} = Output.latest_video(output)

    send(runtime, {:tick, generation})
    :sys.get_state(runtime)
    refute_received {:video_frame, :timer_test, _number}

    assert_receive {:video_frame, :timer_test, 2}, to_timeout(millisecond: 200)
    assert %VideoFrame{number: 2} = Output.latest_video(output)
  end

  defp rom do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0xC3, 0x50, 0x01>>)
    |> put_bytes(0x134, "SCENIC TEST" <> :binary.copy(<<0>>, 5))
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
