defmodule Beamicom.NES.OutputTest do
  # Shares the application-started Output (global name + ETS table).
  use ExUnit.Case, async: false

  alias Beamicom.Host.{AudioChunk, VideoFrame}
  alias Beamicom.NES.{Framebuffer, Output, Runtime}

  defmodule DeferredRenderer do
    def prepare_chr(_chr), do: nil
    def output_dimensions(_state), do: {2, 1}

    def render(lines, _palette, _grayscale, _edge_mask, _state, _frame_number)
        when length(lines) == 240 do
      {:binary.copy(<<0>>, 256 * 240), <<1, 2, 3, 4, 5, 6>>}
    end
  end

  defmodule SlowFirstRenderer do
    def prepare_chr(_chr), do: nil
    def output_dimensions(_state), do: {1, 1}

    def render(lines, _palette, _grayscale, _edge_mask, _state, _frame_number)
        when length(lines) == 240 do
      unless Process.get({__MODULE__, :warmed_up}) do
        Process.put({__MODULE__, :warmed_up}, true)
        Process.sleep(80)
      end

      {:binary.copy(<<0>>, 256 * 240), <<0, 0, 0>>}
    end
  end

  test "publish stores the latest frame and notifies subscribers" do
    Output.subscribe()
    frame = %Framebuffer{number: 7, pixels: <<>>, palette: <<>>}
    Output.publish(frame)

    assert_receive {:frame, 7}
    assert %Framebuffer{number: 7} = Output.latest()
  end

  test "audio PCM binaries are streamed to subscribers with their sample count" do
    Output.subscribe()
    pcm = <<1::signed-little-16, 2::signed-little-16, 3::signed-little-16>>
    Output.publish_audio(3, pcm)
    assert_receive {:audio, 3, ^pcm}
  end

  test "new hosts can consume typed envelopes without changing legacy subscribers" do
    Output.subscribe_video_frames()
    Output.subscribe_audio_chunks()

    frame = %Framebuffer{number: 8, pixels: <<>>, palette: <<>>}
    pcm = <<1::signed-little-16>>
    Output.publish(frame)
    Output.publish_audio(1, pcm)

    assert_receive {:video_frame, :nes, 8}
    assert %VideoFrame{system: :nes, number: 8, data: ^frame} = Output.latest_video()

    assert_receive {:audio_chunk,
                    %AudioChunk{
                      system: :nes,
                      sample_rate: 44_100,
                      channels: 1,
                      frame_count: 1,
                      data: ^pcm
                    }}
  end

  test "legacy video notifications coalesce until the latest frame is read" do
    Output.subscribe_video()

    Enum.each(20..30, fn number ->
      Output.publish(%Framebuffer{number: number, pixels: <<>>, palette: <<>>})
    end)

    _state = :sys.get_state(Output)
    assert_receive {:frame, 20}
    assert %Framebuffer{number: 30} = Output.latest()
    refute_receive {:frame, _number}

    Output.publish(%Framebuffer{number: 31, pixels: <<>>, palette: <<>>})
    assert_receive {:frame, 31}
  end

  @tag :tmp_dir
  test "runtime loads a ROM and publishes frames to the hub", %{tmp_dir: tmp} do
    # Minimal NROM: reset vector -> $8000, where `JMP $8000` spins forever. The
    # PPU still produces frames while the CPU loops.
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>

    rom =
      <<"NES", 0x1A, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>> <> prg <> <<0::size(8192 * 8)>>

    path = Path.join(tmp, "spin.nes")
    File.write!(path, rom)

    Output.subscribe()
    start_supervised!({Runtime, rom: path, pace: false, name: :test_runtime})

    assert_receive {:frame, n} when is_integer(n) and n >= 0, 2000
    assert %Framebuffer{} = Output.latest()

    assert_receive {:audio, sample_count, pcm}
                   when is_integer(sample_count) and sample_count > 0 and is_binary(pcm),
                   2000

    assert byte_size(pcm) == sample_count * 2
    assert_receive {:frame, n} when is_integer(n) and n >= 1, 2000
    assert_receive {:audio, sample_count, pcm} when is_binary(pcm), 2000
    assert sample_count in 700..750
    assert byte_size(pcm) == sample_count * 2
    assert %Framebuffer{width: 256, height: 240} = Output.latest()

    assert :ok = Runtime.set_enhancement(:test_runtime, :hide_horizontal_overscan, true)
    assert :ok = Runtime.set_enhancement(:test_runtime, :unlimited_sprites, true)
    {console, _frame} = Runtime.snapshot(:test_runtime)
    assert console.bus.ppu.hide_horizontal_overscan
    assert console.bus.ppu.unlimited_sprites

    assert {:error, :invalid_enhancement} =
             Runtime.set_enhancement(:test_runtime, :unknown, true)
  end

  test "runtime resolves deferred renderer output before publishing" do
    Output.subscribe_video()

    console =
      minimal_rom()
      |> Beamicom.NES.Console.load_binary(ppu_renderer: DeferredRenderer)

    start_supervised!({Runtime, console: console, pace: false, name: :deferred_runtime})

    assert_receive {:frame, _number}, 2_000

    assert %Framebuffer{
             pixels: pixels,
             rgb: <<1, 2, 3, 4, 5, 6>>,
             rgb_width: 2,
             rgb_height: 1,
             render: nil
           } = Output.latest()

    assert byte_size(pixels) == 256 * 240
    {snapshot, frame} = Runtime.snapshot(:deferred_runtime)
    assert frame.render == nil
    assert snapshot.bus.ppu.frame_ready.render == nil
  end

  test "runtime rebases pacing after a long renderer stall" do
    Output.subscribe_video()

    console =
      minimal_rom()
      |> Beamicom.NES.Console.load_binary(ppu_renderer: SlowFirstRenderer)

    started_at = System.monotonic_time(:nanosecond)
    start_supervised!({Runtime, console: console, pace: true, name: :stalled_runtime})

    assert_receive {:frame, _number}, 2_000
    state = :sys.get_state(:stalled_runtime)

    assert state.slice == 1
    assert state.epoch - started_at >= 50_000_000
  end

  defp minimal_rom do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, 1, 0::size(10 * 8)>> <> prg <> <<0::size(8192 * 8)>>
  end
end
