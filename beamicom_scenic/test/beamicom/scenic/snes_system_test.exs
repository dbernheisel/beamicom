defmodule Beamicom.Scenic.SNESSystemTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.Host.{AudioChunk, Input, VideoFrame}
  alias Beamicom.Scenic.SNESSystem
  alias Beamicom.SNES.DSP
  alias Beamicom.SNES.ShareImage

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

  if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
    test "native and Nx APU renderers agree through a Scenic frame" do
      media = rom(<<0x80, 0xFE>>)

      assert {:ok, native} = SNESSystem.load(media, apu_renderer: :native)

      assert {:ok, nx} =
               SNESSystem.load(media, apu_renderer: Beamicom.SNES.Nx.DSPRenderer)

      assert native.machine.bus.apu.apu_renderer == :native
      assert nx.machine.bus.apu.apu_renderer == Beamicom.SNES.Nx.DSPRenderer

      assert {_native, [%VideoFrame{} = native_video, %AudioChunk{} = native_audio]} =
               SNESSystem.run_slice(native)

      assert {_nx, [%VideoFrame{} = nx_video, %AudioChunk{} = nx_audio]} =
               SNESSystem.run_slice(nx)

      assert native_audio.frame_count >= Beamicom.SNES.Nx.DSPRenderer.minimum_frames()
      assert nx_audio.frame_count == native_audio.frame_count
      assert nx_audio.data == native_audio.data
      assert nx_video.data == native_video.data
    end

    test "Nx echo emits complete stereo chunks through the Scenic boundary" do
      assert {:ok, state} =
               SNESSystem.load(rom(<<0x80, 0xFE>>),
                 apu_renderer: Beamicom.SNES.Nx.DSPRenderer
               )

      state = enable_echo(state)
      assert state.machine.bus.apu.apu_renderer == Beamicom.SNES.Nx.DSPRenderer
      assert DSP.scalar_required?(state.machine.bus.apu.spc.dsp)

      state =
        Enum.reduce(1..3, state, fn _frame, state ->
          assert {state, events} = SNESSystem.run_slice(state)
          audio_chunks = Enum.filter(events, &match?(%AudioChunk{}, &1))

          assert [%AudioChunk{frame_count: frame_count}] = audio_chunks
          assert frame_count >= Beamicom.SNES.Nx.DSPRenderer.synthesis_minimum_frames()

          assert Enum.all?(audio_chunks, fn chunk ->
                   byte_size(chunk.data) == chunk.frame_count * chunk.channels * 2
                 end)

          state
        end)

      assert state.machine.bus.apu.spc.dsp.clock.echo_state.page == 0x20
      assert state.machine.bus.apu.spc.dsp.clock.echo_state.length == 0x0800
    end
  end

  if Code.ensure_loaded?(Beamicom.SNES.Nx.BlarggNTSC) do
    test "applies the selected SNES Blargg filter through the Scenic boundary" do
      options = Beamicom.SNES.Nx.video_options(:composite)

      assert %{video: %{width: 602, height: 224, pixel_scale: {1, 2}}} =
               SNESSystem.capabilities(options)

      assert {:ok, state} = SNESSystem.load(rom(<<0x80, 0xFE>>), options)
      assert {state, [%VideoFrame{} = video, %AudioChunk{}]} = SNESSystem.run_slice(state)

      assert {video.width, video.height, video.pixel_format} == {602, 224, :rgb24}
      assert byte_size(video.data) == 602 * 224 * 3
      assert state.machine.bus.ppu.video_filter == Beamicom.SNES.Nx.BlarggNTSC
    end
  end

  test "freezes stopped CPU work while retaining an inspectable video surface" do
    assert {:ok, state} = SNESSystem.load(rom(<<0xDB>>))
    assert {halted, [%VideoFrame{} = first]} = SNESSystem.run_slice(state)
    refute is_nil(halted.halted)

    assert {halted, [%VideoFrame{} = second]} = SNESSystem.run_slice(halted)
    assert second.number == first.number + 1

    updated = SNESSystem.set_input(halted, Input.new(1, [:a]))
    assert Beamicom.SNES.Bus.joypad_report(updated.machine.bus, 1) == 0x0080
    assert updated.halted == halted.halted
  end

  test "maps Scenic controls to the standard SNES joypad report" do
    assert {:ok, state} = SNESSystem.load(rom(<<0x80, 0xFE>>))

    state =
      SNESSystem.set_input(
        state,
        Input.new(1, [:b, :y, :select, :start, :left, :a, :x, :l, :r])
      )

    assert Beamicom.SNES.Bus.joypad_report(state.machine.bus, 1) == 0xF2F0
  end

  test "continues from a share-image snapshot of an executed frame" do
    assert {:ok, state} = SNESSystem.load(rom(<<0x80, 0xFE>>))
    assert {state, [%VideoFrame{} = video, %AudioChunk{}]} = SNESSystem.run_slice(state)

    png = ShareImage.to_png(state.machine, video.data)
    assert ShareImage.classify(png) == :snes
    assert {:ok, machine} = ShareImage.load_image(png)
    assert {:ok, restored} = SNESSystem.restore(machine)

    assert {continued, [%VideoFrame{}, %AudioChunk{}]} = SNESSystem.run_slice(restored)
    assert continued.halted == nil
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

  defp enable_echo(state) do
    dsp =
      state.machine.bus.apu.spc.dsp
      |> DSP.write(0x0D, 0x20)
      |> DSP.write(0x0F, 0x7F)
      |> DSP.write(0x2C, 0x7F)
      |> DSP.write(0x3C, 0x80)
      |> DSP.write(0x4D, 0x01)
      |> DSP.write(0x6D, 0x20)
      |> DSP.write(0x7D, 0x01)

    put_in(state.machine.bus.apu.spc.dsp, dsp)
  end

  defp put_byte(binary, offset, byte), do: put_bytes(binary, offset, <<byte>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
