defmodule Beamicom.SNES.DSP.Voice do
  @moduledoc """
  Clocked state and immutable bus boundary for one S-DSP voice.

  `synthesize/7` performs voice stage 3c: KON delay, Gaussian interpolation,
  envelope output, reset/end release, key collisions, and the envelope hook for
  the following sample. `advance_pitch/4` performs voice stage 4 and delegates
  the split BRR decode to `DSP.BRR`.

  The ordering follows the independently derived
  [ares voice pipeline](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/voice.cpp).
  `accumulate/4` remains the frozen A20 bus interface.
  """

  import Bitwise

  alias Beamicom.SNES.DSP.{Arithmetic, BRR, Envelope, Gaussian, Mixer, Pipeline}

  @silence List.duplicate(0, 12) |> List.to_tuple()
  @release Envelope.release()
  @attack Envelope.attack()

  @compile {:inline,
            contribution: 3,
            advance_keyon_state: 3,
            envelope_output: 6,
            apply_envelope: 2,
            interpolate: 3,
            wrap_buffer_offset: 1}

  defstruct index: 0,
            active?: false,
            volume: {0, 0},
            pitch: 0,
            source: 0,
            adsr0: 0,
            adsr1: 0,
            gain: 0,
            envx: 0,
            output: 0,
            buffer: @silence,
            buffer_offset: 0,
            gaussian_offset: 0,
            brr_address: 0,
            brr_offset: 1,
            keyon_delay: 0,
            envelope_mode: Envelope.release(),
            envelope: 0,
            hidden_envelope: 0,
            looped?: false

  def new(index) when index in 0..7, do: %__MODULE__{index: index}

  def accumulate(%Pipeline{} = pipeline, index, sample, contribution) when index in 0..7 do
    pipeline = Pipeline.record_voice(pipeline, index, sample)
    %{pipeline | main_bus: Mixer.accumulate(pipeline.main_bus, contribution)}
  end

  def apply_keys(%__MODULE__{} = voice, {key_on?, key_off?}) do
    voice =
      if key_off?,
        do: %{voice | envelope_mode: @release},
        else: voice

    if key_on? do
      %{
        voice
        | active?: true,
          keyon_delay: 5,
          envelope_mode: @attack
      }
    else
      voice
    end
  end

  def synthesize(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter
      ),
      do:
        synthesize(voice, pitch, next_address, header, key_signals, reset?, counter, voice.adsr0)

  def synthesize(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch
      ),
      do:
        synthesize(
          voice,
          pitch,
          next_address,
          header,
          key_signals,
          reset?,
          counter,
          adsr0_latch,
          :decoded
        )

  def synthesize(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source
      ) do
    {voice, output, pitch, header} =
      synthesize_tuple(
        voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source
      )

    %{voice: voice, output: output, pitch: pitch, header: header}
  end

  @doc false
  def synthesize_tuple(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch
      ),
      do:
        synthesize_tuple(
          voice,
          pitch,
          next_address,
          header,
          key_signals,
          reset?,
          counter,
          adsr0_latch,
          :decoded
        )

  def synthesize_tuple(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source
      ) do
    {state, output, pitch, header} =
      synthesis_state(
        voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source
      )

    voice = apply_synthesis_state(voice, state, output)

    {voice, output, pitch, header}
  end

  @doc false
  def synthesize_and_advance_tuple(
        %__MODULE__{
          keyon_delay: 0,
          active?: true,
          buffer: buffer,
          buffer_offset: buffer_offset,
          gaussian_offset: gaussian_offset,
          envelope: envelope,
          envelope_mode: envelope_mode,
          hidden_envelope: hidden_envelope,
          adsr1: adsr1,
          gain: gain,
          brr_address: brr_address,
          brr_offset: brr_offset
        } = voice,
        pitch,
        next_address,
        header,
        {false, false},
        false,
        counter,
        adsr0_latch,
        :decoded,
        brr_byte,
        ram
      ) do
    output = buffer |> interpolate(buffer_offset, gaussian_offset) |> apply_envelope(envelope)

    envx = envelope >>> 4
    release? = (header &&& 0x03) == 0x01
    envelope = if release?, do: 0, else: envelope
    envelope_mode = if release?, do: @release, else: envelope_mode

    {active?, envelope, envelope_mode, hidden_envelope} =
      Envelope.advance(
        true,
        envelope,
        envelope_mode,
        hidden_envelope,
        adsr0_latch,
        adsr1,
        gain,
        counter
      )

    {buffer, buffer_offset, brr_address, brr_offset, looped?, _ended?} =
      if gaussian_offset >= 0x4000 do
        BRR.decode_values(
          brr_byte,
          header,
          next_address,
          buffer,
          buffer_offset,
          brr_address,
          brr_offset,
          ram
        )
      else
        {buffer, buffer_offset, brr_address, brr_offset, false, false}
      end

    gaussian_offset = min((gaussian_offset &&& 0x3FFF) + pitch, 0x7FFF)

    voice = %{
      voice
      | active?: active?,
        envelope_mode: envelope_mode,
        envelope: envelope,
        hidden_envelope: hidden_envelope,
        output: output,
        envx: envx,
        buffer: buffer,
        buffer_offset: buffer_offset,
        brr_address: brr_address,
        brr_offset: brr_offset,
        gaussian_offset: gaussian_offset,
        looped?: looped?
    }

    {voice, output, header}
  end

  def synthesize_and_advance_tuple(
        %__MODULE__{} = voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source,
        brr_byte,
        ram
      ) do
    {state, output, pitch, header} =
      synthesis_state(
        voice,
        pitch,
        next_address,
        header,
        key_signals,
        reset?,
        counter,
        adsr0_latch,
        source
      )

    {active?, keyon_delay, envelope_mode, envelope, hidden_envelope, envx, brr_address,
     brr_offset, buffer_offset, gaussian_offset} = state

    {buffer, buffer_offset, brr_address, brr_offset, looped?, _ended?} =
      if gaussian_offset >= 0x4000 do
        BRR.decode_values(
          brr_byte,
          header,
          next_address,
          voice.buffer,
          buffer_offset,
          brr_address,
          brr_offset,
          ram
        )
      else
        {voice.buffer, buffer_offset, brr_address, brr_offset, false, false}
      end

    gaussian_offset = min((gaussian_offset &&& 0x3FFF) + pitch, 0x7FFF)

    voice = %{
      voice
      | active?: active?,
        keyon_delay: keyon_delay,
        envelope_mode: envelope_mode,
        envelope: envelope,
        hidden_envelope: hidden_envelope,
        output: output,
        envx: envx,
        buffer: buffer,
        buffer_offset: buffer_offset,
        brr_address: brr_address,
        brr_offset: brr_offset,
        gaussian_offset: gaussian_offset,
        looped?: looped?
    }

    {voice, output, header}
  end

  def advance_pitch(%__MODULE__{} = voice, pitch, %BRR{} = brr, ram) do
    if voice.gaussian_offset >= 0x4000 do
      {brr, voice, ended?} = BRR.decode(brr, voice, ram)
      gaussian_offset = min((voice.gaussian_offset &&& 0x3FFF) + pitch, 0x7FFF)
      {brr, %{voice | gaussian_offset: gaussian_offset}, ended?}
    else
      gaussian_offset = min((voice.gaussian_offset &&& 0x3FFF) + pitch, 0x7FFF)
      {brr, %{voice | gaussian_offset: gaussian_offset, looped?: false}, false}
    end
  end

  def contribution(%__MODULE__{} = voice, output, :left),
    do: Arithmetic.shift_right(output * elem(voice.volume, 0), 7)

  def contribution(%__MODULE__{} = voice, output, :right),
    do: Arithmetic.shift_right(output * elem(voice.volume, 1), 7)

  defp synthesis_state(
         voice,
         pitch,
         next_address,
         header,
         key_signals,
         reset?,
         counter,
         adsr0_latch,
         source
       ) do
    initial_delay = voice.keyon_delay

    {pitch, brr_address, brr_offset, buffer_offset, gaussian_offset, envelope, hidden_envelope,
     keyon_delay} = advance_keyon_state(voice, pitch, next_address)

    header = if initial_delay == 5, do: 0, else: header

    output =
      envelope_output(
        voice.active?,
        voice.buffer,
        buffer_offset,
        gaussian_offset,
        envelope,
        source
      )

    envx = envelope >>> 4
    {key_on?, key_off?} = key_signals
    release? = reset? or (header &&& 0x03) == 0x01
    envelope = if release?, do: 0, else: envelope
    envelope_mode = if release? or key_off?, do: @release, else: voice.envelope_mode
    active? = if key_on?, do: true, else: voice.active?
    keyon_delay = if key_on?, do: 5, else: keyon_delay
    envelope_mode = if key_on?, do: @attack, else: envelope_mode

    {active?, envelope, envelope_mode, hidden_envelope} =
      if keyon_delay > 0 do
        {active?, envelope, envelope_mode, hidden_envelope}
      else
        Envelope.advance(
          active?,
          envelope,
          envelope_mode,
          hidden_envelope,
          adsr0_latch,
          voice.adsr1,
          voice.gain,
          counter
        )
      end

    state =
      {active?, keyon_delay, envelope_mode, envelope, hidden_envelope, envx, brr_address,
       brr_offset, buffer_offset, gaussian_offset}

    {state, output, pitch, header}
  end

  defp advance_keyon_state(%__MODULE__{keyon_delay: 0} = voice, pitch, _next_address) do
    {pitch, voice.brr_address, voice.brr_offset, voice.buffer_offset, voice.gaussian_offset,
     voice.envelope, voice.hidden_envelope, 0}
  end

  defp advance_keyon_state(%__MODULE__{} = voice, _pitch, next_address) do
    keyon_delay = voice.keyon_delay - 1
    gaussian_offset = if (keyon_delay &&& 0x03) != 0, do: 0x4000, else: 0
    initial? = voice.keyon_delay == 5

    {0, if(initial?, do: next_address, else: voice.brr_address),
     if(initial?, do: 1, else: voice.brr_offset), if(initial?, do: 0, else: voice.buffer_offset),
     gaussian_offset, 0, 0, keyon_delay}
  end

  defp apply_synthesis_state(voice, state, output) do
    {active?, keyon_delay, envelope_mode, envelope, hidden_envelope, envx, brr_address,
     brr_offset, buffer_offset, gaussian_offset} = state

    %{
      voice
      | active?: active?,
        keyon_delay: keyon_delay,
        envelope_mode: envelope_mode,
        envelope: envelope,
        hidden_envelope: hidden_envelope,
        output: output,
        envx: envx,
        brr_address: brr_address,
        brr_offset: brr_offset,
        buffer_offset: buffer_offset,
        gaussian_offset: gaussian_offset
    }
  end

  defp envelope_output(false, _buffer, _buffer_offset, _gaussian_offset, _envelope, _source),
    do: 0

  defp envelope_output(true, buffer, buffer_offset, gaussian_offset, envelope, :decoded) do
    buffer
    |> interpolate(buffer_offset, gaussian_offset)
    |> apply_envelope(envelope)
  end

  defp envelope_output(true, _buffer, _buffer_offset, _gaussian_offset, envelope, source)
       when is_integer(source),
       do: apply_envelope(source, envelope)

  defp apply_envelope(source, envelope) do
    source
    |> Kernel.*(envelope)
    |> Arithmetic.shift_right(11)
    |> band(0xFFFE)
    |> Arithmetic.signed16()
  end

  defp interpolate(buffer, buffer_offset, gaussian_offset) do
    integer_offset = gaussian_offset >>> 12
    first = wrap_buffer_offset(buffer_offset + integer_offset)
    second = wrap_buffer_offset(first + 1)
    third = wrap_buffer_offset(second + 1)
    fourth = wrap_buffer_offset(third + 1)
    sample0 = elem(buffer, first)
    sample1 = elem(buffer, second)
    sample2 = elem(buffer, third)
    sample3 = elem(buffer, fourth)
    fraction = gaussian_offset >>> 4 &&& 0xFF
    Gaussian.interpolate(sample0, sample1, sample2, sample3, fraction)
  end

  defp wrap_buffer_offset(offset) when offset >= 12, do: offset - 12
  defp wrap_buffer_offset(offset), do: offset
end
