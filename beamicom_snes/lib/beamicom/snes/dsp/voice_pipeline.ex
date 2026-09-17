defmodule Beamicom.SNES.DSP.VoicePipeline do
  @moduledoc """
  Standalone 32-clock A40 voice pipeline ready for top-level integration.

  `clock/3` executes only the operations assigned to one global DSP phase and
  returns observable voice-bus events. It owns shared BRR, pitch, output, key,
  and live-register latches, which prevents eager block decoding and preserves
  cross-voice pipeline collisions.

  The phase table is transcribed from the independently derived
  [ares S-DSP main loop](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/dsp.cpp).
  """

  import Bitwise

  alias Beamicom.SNES.DSP.{
    Arithmetic,
    BRR,
    Envelope,
    Key,
    LiveRegisters,
    Modulation,
    Pipeline,
    Voice
  }

  @operations {
    [{0, 5}, {1, 2}],
    [{0, 6}, {1, 3}],
    [{0, 7}, {1, 4}, {3, 1}],
    [{0, 8}, {1, 5}, {2, 2}],
    [{0, 9}, {1, 6}, {2, 3}],
    [{1, 7}, {2, 4}, {4, 1}],
    [{1, 8}, {2, 5}, {3, 2}],
    [{1, 9}, {2, 6}, {3, 3}],
    [{2, 7}, {3, 4}, {5, 1}],
    [{2, 8}, {3, 5}, {4, 2}],
    [{2, 9}, {3, 6}, {4, 3}],
    [{3, 7}, {4, 4}, {6, 1}],
    [{3, 8}, {4, 5}, {5, 2}],
    [{3, 9}, {4, 6}, {5, 3}],
    [{4, 7}, {5, 4}, {7, 1}],
    [{4, 8}, {5, 5}, {6, 2}],
    [{4, 9}, {5, 6}, {6, 3}],
    [{0, 1}, {5, 7}, {6, 4}],
    [{5, 8}, {6, 5}, {7, 2}],
    [{5, 9}, {6, 6}, {7, 3}],
    [{1, 1}, {6, 7}, {7, 4}],
    [{6, 8}, {7, 5}, {0, 2}],
    [{0, :pitch_high}, {6, 9}, {7, 6}],
    [{7, 7}],
    [{7, 8}],
    [{0, :brr_fetch}, {7, 9}],
    [],
    [],
    [:directory_latch],
    [:key_toggle],
    [:key_poll, {0, :synthesize}],
    [{0, 4}, {2, 1}]
  }
  @sample_operations @operations |> Tuple.to_list() |> List.flatten()
  @live_register_stages 6..9

  @compile {:inline,
            voice: 2,
            execute_voice_left: 3,
            execute_voice_right: 2,
            accumulate_buses: 5,
            accumulate_channel: 3,
            route_echo: 5,
            latch_feature_registers: 2,
            live_output: 1}

  @to_output_operations 24..27
                        |> Enum.flat_map(&elem(@operations, &1))
                        |> Enum.reject(fn
                          {_index, stage} -> stage in @live_register_stages
                          _operation -> false
                        end)

  defmacrop execute_bus_schedule(attribute) do
    {:@, _meta, [{name, _name_meta, _context}]} = attribute
    operations = Module.get_attribute(__CALLER__.module, name)

    steps =
      Enum.map(operations, fn operation ->
        quote generated: true do
          {var!(pipeline), var!(buses)} =
            execute_bus(
              unquote(Macro.escape(operation)),
              var!(pipeline),
              var!(ram),
              var!(buses),
              var!(noise_sample)
            )
        end
      end)

    quote do
      unquote_splicing(steps)
      {var!(pipeline), var!(buses)}
    end
  end

  defstruct voices: nil,
            brr: %BRR{},
            key: %Key{},
            live: %LiveRegisters{},
            adsr0_latch: 0,
            pitch_latch: 0,
            output_latch: 0,
            counter: 0,
            reset?: false,
            muted?: false,
            pmon: 0,
            non: 0,
            eon: 0,
            latched_pmon: 0,
            latched_non: 0,
            latched_eon: 0

  def new do
    voices = 0..7 |> Enum.map(&Voice.new/1) |> List.to_tuple()
    %__MODULE__{voices: voices}
  end

  def operations(phase) when phase in 0..31, do: elem(@operations, phase)

  def voice(%__MODULE__{} = pipeline, index) when index in 0..7,
    do: elem(pipeline.voices, index)

  def replace_voice(%__MODULE__{} = pipeline, index, %Voice{} = voice) when index in 0..7,
    do: %{pipeline | voices: put_elem(pipeline.voices, index, %{voice | index: index})}

  def read(%__MODULE__{} = pipeline, address), do: LiveRegisters.read(pipeline.live, address)

  def write(%__MODULE__{} = pipeline, 0x4C, value),
    do: %{pipeline | key: Key.write_kon(pipeline.key, value)}

  def write(%__MODULE__{} = pipeline, 0x5C, value),
    do: %{pipeline | key: Key.write_koff(pipeline.key, value)}

  def write(%__MODULE__{} = pipeline, 0x6C, value),
    do: %{pipeline | reset?: (value &&& 0x80) != 0, muted?: (value &&& 0x40) != 0}

  def write(%__MODULE__{} = pipeline, 0x7C, value),
    do: %{pipeline | live: LiveRegisters.write(pipeline.live, 0x7C, value)}

  def write(%__MODULE__{} = pipeline, 0x5D, value),
    do: %{pipeline | brr: BRR.write_directory(pipeline.brr, value)}

  def write(%__MODULE__{} = pipeline, 0x2D, value),
    do: %{pipeline | pmon: value &&& 0xFE}

  def write(%__MODULE__{} = pipeline, 0x3D, value),
    do: %{pipeline | non: value &&& 0xFF}

  def write(%__MODULE__{} = pipeline, 0x4D, value),
    do: %{pipeline | eon: value &&& 0xFF}

  def write(%__MODULE__{} = pipeline, address, value)
      when address in 0..0x7F and (address &&& 0x0F) in [0x08, 0x09],
      do: %{pipeline | live: LiveRegisters.write(pipeline.live, address, value)}

  def write(%__MODULE__{} = pipeline, address, value) when address in 0..0x7F do
    index = address >>> 4
    register = address &&& 0x0F
    voice = voice(pipeline, index)
    value = value &&& 0xFF

    voice =
      case register do
        0x00 -> %{voice | volume: put_elem(voice.volume, 0, Arithmetic.signed8(value))}
        0x01 -> %{voice | volume: put_elem(voice.volume, 1, Arithmetic.signed8(value))}
        0x02 -> %{voice | pitch: (voice.pitch &&& 0x3F00) ||| value}
        0x03 -> %{voice | pitch: (value &&& 0x3F) <<< 8 ||| (voice.pitch &&& 0xFF)}
        0x04 -> %{voice | source: value}
        0x05 -> %{voice | adsr0: value}
        0x06 -> %{voice | adsr1: value}
        0x07 -> %{voice | gain: value}
        _other -> voice
      end

    replace_voice(pipeline, index, voice)
  end

  def clock(%__MODULE__{} = pipeline, ram, phase) when phase in 0..31 do
    {pipeline, events} =
      Enum.reduce(operations(phase), {pipeline, []}, fn operation, {pipeline, events} ->
        execute(operation, pipeline, ram, events)
      end)

    {pipeline, Enum.reverse(events)}
  end

  @doc "Advances one phase while accumulating the authoritative main and echo buses."
  def clock_bus(
        %__MODULE__{} = pipeline,
        ram,
        phase,
        %Pipeline{} = buses,
        noise_sample
      )
      when phase in 0..31 and is_integer(noise_sample) do
    pipeline = latch_feature_registers(pipeline, phase)

    Enum.reduce(operations(phase), {pipeline, buses}, fn operation, {pipeline, buses} ->
      execute_bus(operation, pipeline, ram, buses, noise_sample)
    end)
  end

  @doc false
  def advance_bus_before_echo(
        %__MODULE__{} = pipeline,
        ram,
        %Pipeline{} = buses,
        noise_sample
      )
      when is_integer(noise_sample) do
    # Phases 0 through 22 retire one voice at a time once voice 0's right
    # channel has completed. Keep the shared BRR latches in their hardware
    # order while carrying hot state in one compact tuple.
    state = begin_voice_windows(pipeline, ram, buses)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 1, 3, 2)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 2, 4, 3)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 3, 5, 4)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 4, 6, 5)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 5, 7, 6)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 6, 0, 7)
    state = advance_voice_window(state, pipeline, ram, noise_sample, 7, 1, 0)

    {voices, brr, end_flags, adsr0_latch, pitch_latch, output_latch, voice_outputs,
     completed_voices, main_bus, echo_bus} = state

    # Voice 0 is split across the sample boundary: stage 2 runs above, but its
    # pitch-high latch is phase 22 and synthesis does not occur until phase 30.
    voice0 = elem(voices, 0)
    pitch_latch = pitch_latch ||| (voice0.pitch &&& 0x3F00)

    pipeline = %{
      pipeline
      | voices: voices,
        brr: brr,
        live: %{pipeline.live | end_flags: end_flags},
        adsr0_latch: adsr0_latch,
        pitch_latch: pitch_latch,
        output_latch: output_latch
    }

    buses = %{
      buses
      | voice_outputs: voice_outputs,
        completed_voices: completed_voices,
        main_bus: main_bus,
        echo_bus: echo_bus
    }

    {pipeline, buses}
  end

  @doc false
  def advance_bus_to_output(
        %__MODULE__{} = pipeline,
        ram,
        %Pipeline{} = buses,
        noise_sample
      )
      when is_integer(noise_sample) do
    {pipeline, buses} = execute_bus_schedule(@to_output_operations)

    {latch_feature_registers(pipeline, 27), buses}
  end

  @doc false
  def publish_aligned_live(%__MODULE__{} = pipeline, voice0_envx, voice0_output) do
    voice1 = voice(pipeline, 1)
    voice2 = voice(pipeline, 2)
    voice3 = voice(pipeline, 3)
    voice4 = voice(pipeline, 4)
    voice5 = voice(pipeline, 5)
    voice6 = voice(pipeline, 6)
    voice7 = voice(pipeline, 7)

    envx =
      {voice0_envx, voice1.envx, voice2.envx, voice3.envx, voice4.envx, voice5.envx, voice6.envx,
       voice7.envx}

    outx =
      {live_output(voice0_output), live_output(voice1.output), live_output(voice2.output),
       live_output(voice3.output), live_output(voice4.output), live_output(voice5.output),
       live_output(voice6.output), live_output(voice7.output)}

    live = %{
      pipeline.live
      | envx: envx,
        outx: outx,
        envx_latch: voice7.envx,
        outx_latch: live_output(voice7.output),
        published_endx: pipeline.live.end_flags
    }

    %{pipeline | live: live}
  end

  @doc "Advances all 32 phases and returns the accumulated buses."
  def advance_sample_bus(
        %__MODULE__{} = pipeline,
        ram,
        %Pipeline{} = buses,
        noise_sample
      )
      when is_integer(noise_sample) do
    Enum.reduce(0..31, {pipeline, buses}, fn phase, {pipeline, buses} ->
      clock_bus(pipeline, ram, phase, buses, noise_sample)
    end)
  end

  @doc false
  def advance_sample(%__MODULE__{} = pipeline, ram) do
    Enum.reduce(@sample_operations, pipeline, fn operation, pipeline ->
      execute_without_events(operation, pipeline, ram)
    end)
  end

  defp execute(:directory_latch, pipeline, _ram, events),
    do: {%{pipeline | brr: BRR.latch_directory(pipeline.brr)}, events}

  defp execute(:key_toggle, pipeline, _ram, events),
    do: {%{pipeline | key: Key.phase29(pipeline.key)}, events}

  defp execute(:key_poll, pipeline, _ram, events) do
    pipeline = %{
      pipeline
      | key: Key.phase30(pipeline.key),
        counter: Envelope.next_counter(pipeline.counter)
    }

    {pipeline, events}
  end

  defp execute({index, 1}, pipeline, _ram, events) do
    voice = voice(pipeline, index)
    {%{pipeline | brr: BRR.directory_stage(pipeline.brr, voice.source)}, events}
  end

  defp execute({index, 2}, pipeline, ram, events) do
    voice = voice(pipeline, index)

    pipeline = %{
      pipeline
      | brr: BRR.pointer_stage(pipeline.brr, ram, voice.keyon_delay),
        adsr0_latch: voice.adsr0,
        pitch_latch: voice.pitch &&& 0xFF
    }

    {pipeline, events}
  end

  defp execute({index, 3}, pipeline, ram, events) do
    {pipeline, events} = execute({index, :pitch_high}, pipeline, ram, events)
    {pipeline, events} = execute({index, :brr_fetch}, pipeline, ram, events)
    execute({index, :synthesize}, pipeline, ram, events)
  end

  defp execute({index, :pitch_high}, pipeline, _ram, events) do
    voice = voice(pipeline, index)
    pitch_latch = pipeline.pitch_latch ||| (voice.pitch &&& 0x3F00)
    {%{pipeline | pitch_latch: pitch_latch}, events}
  end

  defp execute({index, :brr_fetch}, pipeline, ram, events) do
    voice = voice(pipeline, index)
    {%{pipeline | brr: BRR.fetch(pipeline.brr, voice, ram)}, events}
  end

  defp execute({index, :synthesize}, pipeline, _ram, events) do
    voice = voice(pipeline, index)

    key_signals =
      if pipeline.key.sample_poll?, do: Key.signals(pipeline.key, index), else: {false, false}

    {voice, output, pitch, header} =
      Voice.synthesize_tuple(
        voice,
        pipeline.pitch_latch,
        pipeline.brr.next_address,
        pipeline.brr.header,
        key_signals,
        pipeline.reset?,
        pipeline.counter,
        pipeline.adsr0_latch
      )

    voices = put_elem(pipeline.voices, index, %{voice | index: index})

    pipeline = %{
      pipeline
      | voices: voices,
        pitch_latch: pitch,
        output_latch: output,
        brr: %{pipeline.brr | header: header}
    }

    {pipeline, events}
  end

  defp execute({index, 4}, pipeline, ram, events) do
    {pipeline, contribution} = execute_voice_left(pipeline, index, ram)
    {pipeline, [{:voice_output, index, :left, contribution} | events]}
  end

  defp execute({index, 5}, pipeline, _ram, events) do
    {pipeline, contribution} = execute_voice_right(pipeline, index)
    {pipeline, [{:voice_output, index, :right, contribution} | events]}
  end

  defp execute({_index, 6}, pipeline, _ram, events),
    do:
      {%{pipeline | live: LiveRegisters.capture_outx(pipeline.live, pipeline.output_latch)},
       events}

  defp execute({index, 7}, pipeline, _ram, events) do
    voice = voice(pipeline, index)

    live =
      pipeline.live
      |> LiveRegisters.publish_endx()
      |> LiveRegisters.capture_envx_value(voice.envx)

    {%{pipeline | live: live}, events}
  end

  defp execute({index, 8}, pipeline, _ram, events),
    do: {%{pipeline | live: LiveRegisters.publish_outx(pipeline.live, index)}, events}

  defp execute({index, 9}, pipeline, _ram, events),
    do: {%{pipeline | live: LiveRegisters.publish_envx(pipeline.live, index)}, events}

  defp execute_bus({index, 3}, pipeline, ram, buses, noise_sample) do
    {pipeline, buses} =
      execute_bus({index, :pitch_high}, pipeline, ram, buses, noise_sample)

    {pipeline, buses} =
      execute_bus({index, :brr_fetch}, pipeline, ram, buses, noise_sample)

    execute_bus({index, :synthesize}, pipeline, ram, buses, noise_sample)
  end

  defp execute_bus({index, :synthesize}, pipeline, _ram, buses, noise_sample) do
    voice = voice(pipeline, index)

    key_signals =
      if pipeline.key.sample_poll?, do: Key.signals(pipeline.key, index), else: {false, false}

    pitch = Modulation.pitch(pipeline.pitch_latch, index, pipeline.latched_pmon, buses)
    source = if (pipeline.latched_non &&& 1 <<< index) != 0, do: noise_sample, else: :decoded

    {voice, output, pitch, header} =
      Voice.synthesize_tuple(
        voice,
        pitch,
        pipeline.brr.next_address,
        pipeline.brr.header,
        key_signals,
        pipeline.reset?,
        pipeline.counter,
        pipeline.adsr0_latch,
        source
      )

    voice = %{voice | index: index}

    pipeline = %{
      pipeline
      | voices: put_elem(pipeline.voices, index, voice),
        pitch_latch: pitch,
        output_latch: output,
        brr: %{pipeline.brr | header: header}
    }

    {pipeline, buses}
  end

  defp execute_bus({index, 4}, pipeline, ram, buses, _noise_sample) do
    {pipeline, contribution} = execute_voice_left(pipeline, index, ram)
    buses = accumulate_buses(buses, pipeline, index, contribution, :left)
    {pipeline, buses}
  end

  defp execute_bus({index, 5}, pipeline, _ram, buses, _noise_sample) do
    {pipeline, contribution} = execute_voice_right(pipeline, index)
    buses = accumulate_buses(buses, pipeline, index, contribution, :right)
    {pipeline, buses}
  end

  defp execute_bus(operation, pipeline, ram, buses, _noise_sample) do
    {execute_without_events(operation, pipeline, ram), buses}
  end

  defp accumulate_buses(buses, voice_pipeline, index, contribution, :left) do
    %{
      buses
      | voice_outputs: put_elem(buses.voice_outputs, index, voice_pipeline.output_latch),
        completed_voices: buses.completed_voices ||| 1 <<< index,
        main_bus: accumulate_channel(buses.main_bus, contribution, :left),
        echo_bus:
          route_echo(buses.echo_bus, index, contribution, :left, voice_pipeline.latched_eon)
    }
  end

  defp accumulate_buses(buses, voice_pipeline, index, contribution, :right) do
    %{
      buses
      | main_bus: accumulate_channel(buses.main_bus, contribution, :right),
        echo_bus:
          route_echo(buses.echo_bus, index, contribution, :right, voice_pipeline.latched_eon)
    }
  end

  defp route_echo(bus, index, contribution, channel, eon) do
    if (eon &&& 1 <<< index) != 0,
      do: accumulate_channel(bus, contribution, channel),
      else: bus
  end

  defp accumulate_channel({left, right}, contribution, :left),
    do: {Arithmetic.clamp16(left + contribution), Arithmetic.clamp16(right)}

  defp accumulate_channel({left, right}, contribution, :right),
    do: {Arithmetic.clamp16(left), Arithmetic.clamp16(right + contribution)}

  defp latch_feature_registers(pipeline, 27),
    do: %{pipeline | latched_pmon: pipeline.pmon &&& 0xFE}

  defp latch_feature_registers(pipeline, 28),
    do: %{pipeline | latched_non: pipeline.non, latched_eon: pipeline.eon}

  defp latch_feature_registers(pipeline, _phase), do: pipeline

  defp execute_without_events({index, 4}, pipeline, ram),
    do: pipeline |> execute_voice_left(index, ram) |> elem(0)

  defp execute_without_events({index, 5}, pipeline, _ram),
    do: pipeline |> execute_voice_right(index) |> elem(0)

  defp execute_without_events(:directory_latch, pipeline, _ram),
    do: %{pipeline | brr: BRR.latch_directory(pipeline.brr)}

  defp execute_without_events(:key_toggle, pipeline, _ram),
    do: %{pipeline | key: Key.phase29(pipeline.key)}

  defp execute_without_events(:key_poll, pipeline, _ram) do
    %{
      pipeline
      | key: Key.phase30(pipeline.key),
        counter: Envelope.next_counter(pipeline.counter)
    }
  end

  defp execute_without_events({index, 1}, pipeline, _ram) do
    voice = voice(pipeline, index)
    %{pipeline | brr: BRR.directory_stage(pipeline.brr, voice.source)}
  end

  defp execute_without_events({index, 2}, pipeline, ram) do
    voice = voice(pipeline, index)

    %{
      pipeline
      | brr: BRR.pointer_stage(pipeline.brr, ram, voice.keyon_delay),
        adsr0_latch: voice.adsr0,
        pitch_latch: voice.pitch &&& 0xFF
    }
  end

  defp execute_without_events({index, 3}, pipeline, ram) do
    pipeline = execute_without_events({index, :pitch_high}, pipeline, ram)
    pipeline = execute_without_events({index, :brr_fetch}, pipeline, ram)
    execute_without_events({index, :synthesize}, pipeline, ram)
  end

  defp execute_without_events({index, :pitch_high}, pipeline, _ram) do
    voice = voice(pipeline, index)
    %{pipeline | pitch_latch: pipeline.pitch_latch ||| (voice.pitch &&& 0x3F00)}
  end

  defp execute_without_events({index, :brr_fetch}, pipeline, ram) do
    voice = voice(pipeline, index)
    %{pipeline | brr: BRR.fetch(pipeline.brr, voice, ram)}
  end

  defp execute_without_events({index, :synthesize}, pipeline, _ram) do
    voice = voice(pipeline, index)

    key_signals =
      if pipeline.key.sample_poll?, do: Key.signals(pipeline.key, index), else: {false, false}

    {voice, output, pitch, header} =
      Voice.synthesize_tuple(
        voice,
        pipeline.pitch_latch,
        pipeline.brr.next_address,
        pipeline.brr.header,
        key_signals,
        pipeline.reset?,
        pipeline.counter,
        pipeline.adsr0_latch
      )

    voices = put_elem(pipeline.voices, index, %{voice | index: index})

    %{
      pipeline
      | voices: voices,
        pitch_latch: pitch,
        output_latch: output,
        brr: %{pipeline.brr | header: header}
    }
  end

  defp execute_without_events({_index, 6}, pipeline, _ram),
    do: %{pipeline | live: LiveRegisters.capture_outx(pipeline.live, pipeline.output_latch)}

  defp execute_without_events({index, 7}, pipeline, _ram) do
    voice = voice(pipeline, index)

    live =
      pipeline.live
      |> LiveRegisters.publish_endx()
      |> LiveRegisters.capture_envx_value(voice.envx)

    %{pipeline | live: live}
  end

  defp execute_without_events({index, 8}, pipeline, _ram),
    do: %{pipeline | live: LiveRegisters.publish_outx(pipeline.live, index)}

  defp execute_without_events({index, 9}, pipeline, _ram),
    do: %{pipeline | live: LiveRegisters.publish_envx(pipeline.live, index)}

  defp execute_voice_left(pipeline, index, ram) do
    voice = voice(pipeline, index)
    {brr, voice, _ended?} = Voice.advance_pitch(voice, pipeline.pitch_latch, pipeline.brr, ram)
    contribution = Arithmetic.shift_right(pipeline.output_latch * elem(voice.volume, 0), 7)
    pipeline = %{pipeline | voices: put_elem(pipeline.voices, index, voice), brr: brr}
    {pipeline, contribution}
  end

  defp execute_voice_right(pipeline, index) do
    voice = voice(pipeline, index)
    contribution = Arithmetic.shift_right(pipeline.output_latch * elem(voice.volume, 1), 7)
    live = LiveRegisters.record_end(pipeline.live, index, voice.looped?)
    live = if voice.keyon_delay == 5, do: LiveRegisters.clear_voice_end(live, index), else: live
    {%{pipeline | live: live}, contribution}
  end

  defp begin_voice_windows(pipeline, ram, buses) do
    voice0 = voice(pipeline, 0)
    voice1 = voice(pipeline, 1)
    right = Arithmetic.shift_right(pipeline.output_latch * elem(voice0.volume, 1), 7)
    end_flags = record_end_flags(pipeline.live.end_flags, 0, voice0)
    main_bus = accumulate_channel(buses.main_bus, right, :right)

    echo_bus =
      if (pipeline.latched_eon &&& 1) != 0,
        do: accumulate_channel(buses.echo_bus, right, :right),
        else: buses.echo_bus

    brr = BRR.pointer_stage(pipeline.brr, ram, voice1.keyon_delay)

    {pipeline.voices, brr, end_flags, voice1.adsr0, voice1.pitch &&& 0xFF, pipeline.output_latch,
     buses.voice_outputs, buses.completed_voices, main_bus, echo_bus}
  end

  defp advance_voice_window(
         {voices, brr, end_flags, adsr0_latch, pitch_latch, _output_latch, voice_outputs,
          completed_voices, main_bus, echo_bus},
         pipeline,
         ram,
         noise_sample,
         index,
         directory_index,
         pointer_index
       ) do
    voice = elem(voices, index)
    directory_voice = elem(voices, directory_index)
    pointer_voice = elem(voices, pointer_index)
    pitch_latch = pitch_latch ||| (voice.pitch &&& 0x3F00)
    {brr_byte, brr_header} = BRR.fetch_values(brr, voice, ram)

    key_signals =
      if pipeline.key.sample_poll?, do: Key.signals(pipeline.key, index), else: {false, false}

    pitch = modulated_pitch(pitch_latch, index, pipeline.latched_pmon, voice_outputs)
    source = if (pipeline.latched_non &&& 1 <<< index) != 0, do: noise_sample, else: :decoded

    {voice, output, header} =
      Voice.synthesize_and_advance_tuple(
        voice,
        pitch,
        brr.next_address,
        brr_header,
        key_signals,
        pipeline.reset?,
        pipeline.counter,
        adsr0_latch,
        source,
        brr_byte,
        ram
      )

    left = Arithmetic.shift_right(output * elem(voice.volume, 0), 7)
    right = Arithmetic.shift_right(output * elem(voice.volume, 1), 7)
    end_flags = record_end_flags(end_flags, index, voice)

    brr =
      BRR.finish_voice_window(
        brr,
        brr_byte,
        header,
        directory_voice.source,
        pointer_voice.keyon_delay,
        ram
      )

    voices = put_elem(voices, index, %{voice | index: index})
    voice_outputs = put_elem(voice_outputs, index, output)
    completed_voices = completed_voices ||| 1 <<< index
    main_bus = add_stereo(main_bus, left, right)

    echo_bus =
      if (pipeline.latched_eon &&& 1 <<< index) != 0,
        do: add_stereo(echo_bus, left, right),
        else: echo_bus

    {voices, brr, end_flags, pointer_voice.adsr0, pointer_voice.pitch &&& 0xFF, output,
     voice_outputs, completed_voices, main_bus, echo_bus}
  end

  defp modulated_pitch(pitch, 0, _pmon, _voice_outputs), do: pitch

  defp modulated_pitch(pitch, index, pmon, voice_outputs) do
    if (pmon &&& 1 <<< index) != 0,
      do: Modulation.modulated_pitch(pitch, elem(voice_outputs, index - 1)),
      else: pitch
  end

  defp record_end_flags(end_flags, index, voice) do
    mask = 1 <<< index
    end_flags = if voice.looped?, do: end_flags ||| mask, else: end_flags
    if voice.keyon_delay == 5, do: end_flags &&& bnot(mask), else: end_flags
  end

  defp add_stereo({left, right}, add_left, add_right),
    do: {Arithmetic.clamp16(left + add_left), Arithmetic.clamp16(right + add_right)}

  defp live_output(output), do: output >>> 8 &&& 0xFF
end
