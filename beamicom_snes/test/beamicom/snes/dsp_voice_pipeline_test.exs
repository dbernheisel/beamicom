defmodule Beamicom.SNES.DSPVoicePipelineTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.DSP
  alias Beamicom.SNES.DSP.{BRR, Envelope, Key, LiveRegisters, Voice, VoicePipeline}

  test "BRR range and filter arithmetic covers the hardware edge classes" do
    assert BRR.decode_nibble(0x7, 0, 0, 0, 0) == 6
    assert BRR.decode_nibble(0x8, 0, 0, 0, 0) == -8
    assert BRR.decode_nibble(0x7, 12, 0, 0, 0) == 28_672
    assert BRR.decode_nibble(0x8, 12, 0, 0, 0) == -32_768
    assert BRR.decode_nibble(0x7, 13, 0, 0, 0) == 0
    assert BRR.decode_nibble(0x8, 13, 0, 0, 0) == -4_096

    assert BRR.decode_nibble(0, 0, 1, 1_000, -500) == 936
    assert BRR.decode_nibble(0, 0, 2, 1_000, -500) == 2_374
    assert BRR.decode_nibble(0, 0, 3, 1_000, -500) == 2_202
  end

  test "BRR fetch caches the first byte but reads the second byte at decode phase" do
    ram = ram([{0x200, 0x00}, {0x201, 0x11}, {0x202, 0x22}])
    voice = %{Voice.new(0) | active?: true, brr_address: 0x200}
    brr = BRR.new() |> BRR.fetch(voice, ram)

    ram = :array.set(0x201, 0xFF, ram)
    ram = :array.set(0x202, 0x77, ram)
    {_brr, voice, ended?} = BRR.decode(brr, voice, ram)

    refute ended?
    assert Tuple.to_list(voice.buffer) |> Enum.take(4) == [0, 0, 6, 6]
  end

  test "directory stage addresses the previously latched shared source" do
    brr = %{BRR.new() | latched_bank: 0x12, source: 0x03}
    brr = BRR.directory_stage(brr, 0x09)

    assert brr.directory_address == 0x120C
    assert brr.source == 0x09

    brr = BRR.directory_stage(brr, 0x02)
    assert brr.directory_address == 0x1224
    assert brr.source == 0x02
  end

  test "BRR END transitions through the prefetched pointer and exposes ENDX" do
    ram = ram([{0x207, 0xFF}, {0x208, 0xFF}])

    voice = %{
      Voice.new(0)
      | active?: true,
        brr_address: 0x200,
        brr_offset: 7,
        gaussian_offset: 0x4000
    }

    brr = %{BRR.new() | header: 0x03, byte: 0xFF, next_address: 0x3456}
    {_brr, voice, ended?} = BRR.decode(brr, voice, ram)

    assert ended?
    assert voice.looped?
    assert voice.brr_address == 0x3456
    assert voice.brr_offset == 1

    live = LiveRegisters.new() |> LiveRegisters.record_end(0, ended?)
    assert LiveRegisters.end_flags(live) == 0x01
  end

  test "BRR END remains pending until the final four-sample decode" do
    ram = ram([{0x201, 0x11}, {0x202, 0x22}])
    voice = %{Voice.new(0) | active?: true, brr_address: 0x200, brr_offset: 1}
    brr = %{BRR.new() | header: 0x03, byte: 0x11, next_address: 0x3456}
    {_brr, voice, ended?} = BRR.decode(brr, voice, ram)

    refute ended?
    refute voice.looped?
    assert voice.brr_address == 0x200
    assert voice.brr_offset == 3
  end

  test "KON and KOFF poll together, with KON winning the collision stage" do
    key =
      Key.new()
      |> Key.write_kon(0x01)
      |> Key.write_koff(0x01)
      |> Key.phase29()
      |> Key.phase30()

    refute Key.key_on?(key, 0)
    refute Key.key_off?(key, 0)

    key = key |> Key.phase29() |> Key.phase30()
    assert Key.key_on?(key, 0)
    assert Key.key_off?(key, 0)

    voice = %{Voice.new(0) | active?: true, envelope: 0x500}
    voice = Voice.apply_keys(voice, Key.signals(key, 0))

    assert voice.active?
    assert voice.keyon_delay == 5
    assert voice.envelope_mode == Envelope.attack()
  end

  test "ENDX clears when KON begins and a software write clears every internal bit" do
    live =
      LiveRegisters.new()
      |> LiveRegisters.record_end(0, true)
      |> LiveRegisters.record_end(3, true)
      |> LiveRegisters.publish_endx()

    assert LiveRegisters.read(live, 0x7C) == 0x09
    assert LiveRegisters.read(live, 0x08) == 0

    live = LiveRegisters.clear_voice_end(live, 0)
    assert LiveRegisters.end_flags(live) == 0x08

    live = LiveRegisters.write(live, 0x7C, 0xFF)
    assert LiveRegisters.end_flags(live) == 0
    assert LiveRegisters.read(live, 0x7C) == 0
  end

  test "ENVX and OUTX publish on their separate clock stages" do
    live = LiveRegisters.new()

    live = LiveRegisters.capture_outx(live, 0x3456)
    assert LiveRegisters.read(live, 0x09) == 0
    live = LiveRegisters.publish_outx(live, 0)
    assert LiveRegisters.read(live, 0x09) == 0x34

    live = LiveRegisters.capture_envx(live, 0x7FF)
    assert LiveRegisters.read(live, 0x08) == 0
    live = LiveRegisters.publish_envx(live, 0)
    assert LiveRegisters.read(live, 0x08) == 0x7F
  end

  test "a write between capture and publish wins the shared live-register latch" do
    live =
      LiveRegisters.new()
      |> LiveRegisters.capture_outx(0x3456)
      |> LiveRegisters.write(0x39, 0xA5)
      |> LiveRegisters.publish_outx(2)
      |> LiveRegisters.capture_envx(0x7FF)
      |> LiveRegisters.write(0x18, 0x5A)
      |> LiveRegisters.publish_envx(4)

    assert LiveRegisters.read(live, 0x29) == 0xA5
    assert LiveRegisters.read(live, 0x48) == 0x5A
  end

  test "voice operation schedule exposes split voice-zero fetch stages" do
    assert VoicePipeline.operations(0) == [{0, 5}, {1, 2}]
    assert VoicePipeline.operations(22) == [{0, :pitch_high}, {6, 9}, {7, 6}]
    assert VoicePipeline.operations(25) == [{0, :brr_fetch}, {7, 9}]
    assert VoicePipeline.operations(30) == [:key_poll, {0, :synthesize}]
    assert VoicePipeline.operations(31) == [{0, 4}, {2, 1}]
  end

  test "event-free sample advancement preserves all 32 clock phases" do
    ram = ram([{0x200, 0x00}, {0x201, 0x11}])

    pipeline =
      VoicePipeline.new()
      |> VoicePipeline.write(0x00, 0x7F)
      |> VoicePipeline.write(0x02, 0x00)
      |> VoicePipeline.write(0x03, 0x10)
      |> VoicePipeline.replace_voice(0, %{Voice.new(0) | active?: true, brr_address: 0x200})

    clocked =
      Enum.reduce(0..31, pipeline, fn phase, pipeline ->
        {pipeline, _events} = VoicePipeline.clock(pipeline, ram, phase)
        pipeline
      end)

    assert VoicePipeline.advance_sample(pipeline, ram) == clocked
  end

  test "clocked pipeline fetches BRR only at voice fetch phase" do
    pipeline =
      VoicePipeline.new()
      |> VoicePipeline.replace_voice(0, %{
        Voice.new(0)
        | active?: true,
          brr_address: 0x200,
          brr_offset: 1
      })

    ram = ram([{0x200, 0x00}, {0x201, 0x11}, {0x202, 0x22}])
    {pipeline, []} = VoicePipeline.clock(pipeline, ram, 24)
    assert pipeline.brr.byte == 0

    {pipeline, _events} = VoicePipeline.clock(pipeline, ram, 25)
    assert pipeline.brr.byte == 0x11
    assert pipeline.brr.header == 0
  end

  test "ADSR0 remains latched when software writes between voice stages 2 and 3" do
    voice = %{
      Voice.new(1)
      | active?: true,
        adsr0: 0x8F,
        envelope_mode: Envelope.attack()
    }

    pipeline = VoicePipeline.new() |> VoicePipeline.replace_voice(1, voice)
    {pipeline, _events} = VoicePipeline.clock(pipeline, ram([]), 0)
    pipeline = VoicePipeline.write(pipeline, 0x15, 0x00)
    {pipeline, _events} = VoicePipeline.clock(pipeline, ram([]), 1)

    assert VoicePipeline.voice(pipeline, 1).adsr0 == 0
    assert VoicePipeline.voice(pipeline, 1).envelope == 0x400
  end

  test "FLG reset silences and releases internals while mute leaves voice evolution running" do
    voice = %{
      Voice.new(0)
      | active?: true,
        envelope: 0x400,
        hidden_envelope: 0x400,
        envelope_mode: Envelope.sustain(),
        buffer: List.duplicate(2_000, 12) |> List.to_tuple()
    }

    reset = Voice.synthesize(voice, 0, 0, 0, {false, false}, true, 0)
    assert reset.voice.envelope == 0
    assert reset.voice.envelope_mode == Envelope.release()
    assert reset.output == 1_000

    normal = VoicePipeline.new() |> VoicePipeline.replace_voice(0, voice)
    muted = normal |> VoicePipeline.write(0x6C, 0x40)

    {normal, _events} = VoicePipeline.clock(normal, ram([]), 30)
    {muted, _events} = VoicePipeline.clock(muted, ram([]), 30)

    assert muted.muted?
    assert VoicePipeline.voice(muted, 0) == VoicePipeline.voice(normal, 0)
  end

  test "unused A40 hooks do not alter the existing DSP reset state" do
    assert DSP.new() == DSP.new()
  end

  test "production DSP performs BRR fetches at the embedded voice phase" do
    voice = %{Voice.new(0) | active?: true, brr_address: 0x200, brr_offset: 1}

    dsp =
      DSP.new()
      |> put_in(
        [Access.key(:clock), Access.key(:voice_pipeline)],
        VoicePipeline.new() |> VoicePipeline.replace_voice(0, voice)
      )

    ram = ram([{0x200, 0x00}, {0x201, 0x11}])
    {dsp, <<>>} = DSP.clock(dsp, ram, 25)
    assert dsp.clock.voice_pipeline.brr.byte == 0

    {dsp, <<>>} = DSP.clock(dsp, ram, 1)
    assert dsp.clock.voice_pipeline.brr.byte == 0x11
  end

  test "production DSP publishes OUTX only at the voice live-register phase" do
    dsp = DSP.new() |> DSP.write(0x09, 0xA5)
    dsp = put_in(dsp.clock.voice_pipeline.output_latch, 0x3456)

    {dsp, <<>>} = DSP.clock(dsp, ram([]), 2)
    assert DSP.read(dsp, 0x09) == 0xA5

    {dsp, <<>>} = DSP.clock(dsp, ram([]), 2)
    assert DSP.read(dsp, 0x09) == 0x34
  end

  test "production KON is consumed once on the alternating key-poll phase" do
    dsp = DSP.new() |> DSP.write(0x4C, 0x01)

    {dsp, _pcm} = DSP.clock(dsp, ram([]), 31)
    assert VoicePipeline.voice(dsp.clock.voice_pipeline, 0).keyon_delay == 0

    {dsp, _pcm} = DSP.clock(dsp, ram([]), 32)
    assert VoicePipeline.voice(dsp.clock.voice_pipeline, 0).keyon_delay == 5

    {dsp, _pcm} = DSP.clock(dsp, ram([]), 32)
    assert VoicePipeline.voice(dsp.clock.voice_pipeline, 0).keyon_delay == 4
  end

  defp ram(bytes) do
    Enum.reduce(bytes, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end
end
