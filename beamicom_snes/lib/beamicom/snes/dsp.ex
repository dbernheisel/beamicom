defmodule Beamicom.SNES.DSP do
  @moduledoc "Native S-DSP voice mixer with BRR decoding and stereo volume control."

  import Bitwise

  @compile {:inline, reg: 2, ram_get: 2, signed8: 1, clip16: 1}

  @voice %{
    active?: false,
    block_address: 0,
    loop_address: 0,
    block_end?: false,
    block_loop?: false,
    samples: List.duplicate(0, 16) |> List.to_tuple(),
    sample_index: 0,
    phase: 0,
    previous1: 0,
    previous2: 0
  }

  defstruct registers: :array.new(128, default: 0, fixed: true),
            voices: List.duplicate(@voice, 8) |> List.to_tuple(),
            key_on: 0,
            key_off: 0,
            end_flags: 0

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def write(%__MODULE__{} = dsp, address, value) do
    address = address &&& 0x7F
    value = value &&& 0xFF

    case address do
      0x4C ->
        %{
          dsp
          | registers: :array.set(address, value, dsp.registers),
            key_on: value
        }

      0x5C ->
        %{dsp | registers: :array.set(address, value, dsp.registers), key_off: value}

      0x7C ->
        %{dsp | registers: :array.set(address, 0, dsp.registers), end_flags: 0}

      0x6C when (value &&& 0x80) != 0 ->
        %{
          dsp
          | registers: :array.set(address, value, dsp.registers),
            voices: List.duplicate(@voice, 8) |> List.to_tuple()
        }

      _ ->
        %{dsp | registers: :array.set(address, value, dsp.registers)}
    end
  end

  def read(%__MODULE__{} = dsp, 0x7C), do: dsp.end_flags
  def read(%__MODULE__{} = dsp, address), do: :array.get(address &&& 0x7F, dsp.registers)

  @doc "Renders signed-16 little-endian stereo frames from current DSP state."
  def render(%__MODULE__{} = dsp, _ram, 0), do: {dsp, <<>>}

  def render(%__MODULE__{} = dsp, ram, frames) when frames > 0 do
    dsp = apply_keys(dsp, ram)
    mixer = mixer_state(dsp)

    {voices, end_flags, pcm} =
      render_samples(render_voices(dsp.voices), dsp.end_flags, ram, mixer, frames, [])

    dsp = %{dsp | voices: store_voices(voices), end_flags: end_flags}
    {dsp, pcm |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp render_samples(voices, end_flags, _ram, _mixer, 0, pcm),
    do: {voices, end_flags, pcm}

  defp render_samples(voices, end_flags, ram, mixer, remaining, pcm) do
    {left, right, voices, end_flags} = mix_sample(voices, end_flags, ram, mixer)

    render_samples(
      voices,
      end_flags,
      ram,
      mixer,
      remaining - 1,
      [<<left::signed-little-16, right::signed-little-16>> | pcm]
    )
  end

  defp apply_keys(dsp, ram) do
    voices =
      Enum.reduce(0..7, dsp.voices, fn index, voices ->
        voice = elem(voices, index)

        voice =
          cond do
            (dsp.key_on &&& 1 <<< index) != 0 -> start_voice(dsp, ram, index)
            (dsp.key_off &&& 1 <<< index) != 0 -> %{voice | active?: false}
            true -> voice
          end

        put_elem(voices, index, voice)
      end)

    # KON is a self-clearing latch, while KOFF remains asserted until software
    # writes it again. KON wins on the boundary where both are sampled, but an
    # asserted KOFF must still stop that voice on the following boundary.
    %{
      dsp
      | voices: voices,
        key_on: 0,
        end_flags: dsp.end_flags &&& bnot(dsp.key_on)
    }
  end

  defp start_voice(dsp, ram, index) do
    source = reg(dsp, index * 0x10 + 4)
    directory = reg(dsp, 0x5D) <<< 8
    entry = directory + source * 4 &&& 0xFFFF
    start_address = ram_word(ram, entry)
    loop_address = ram_word(ram, entry + 2)

    @voice
    |> Map.merge(%{active?: true, block_address: start_address, loop_address: loop_address})
    |> decode_block(ram)
  end

  defp mixer_state(dsp) do
    voices =
      0..7
      |> Enum.map(fn index ->
        {
          pitch(dsp, index),
          signed8(reg(dsp, index * 0x10)),
          signed8(reg(dsp, index * 0x10 + 1))
        }
      end)
      |> List.to_tuple()

    {
      voices,
      (reg(dsp, 0x6C) &&& 0x40) != 0,
      signed8(reg(dsp, 0x0C)),
      signed8(reg(dsp, 0x1C))
    }
  end

  defp mix_sample(voices, end_flags, ram, {mixer_voices, muted?, master_left, master_right}) do
    {v0, v1, v2, v3, v4, v5, v6, v7} = voices
    {m0, m1, m2, m3, m4, m5, m6, m7} = mixer_voices
    {left, right, v0, end_flags} = mix_voice(v0, m0, ram, 0, 0, 0, end_flags)
    {left, right, v1, end_flags} = mix_voice(v1, m1, ram, 1, left, right, end_flags)
    {left, right, v2, end_flags} = mix_voice(v2, m2, ram, 2, left, right, end_flags)
    {left, right, v3, end_flags} = mix_voice(v3, m3, ram, 3, left, right, end_flags)
    {left, right, v4, end_flags} = mix_voice(v4, m4, ram, 4, left, right, end_flags)
    {left, right, v5, end_flags} = mix_voice(v5, m5, ram, 5, left, right, end_flags)
    {left, right, v6, end_flags} = mix_voice(v6, m6, ram, 6, left, right, end_flags)
    {left, right, v7, end_flags} = mix_voice(v7, m7, ram, 7, left, right, end_flags)

    left = if muted?, do: 0, else: clip16(div(left * master_left, 128))
    right = if muted?, do: 0, else: clip16(div(right * master_right, 128))
    {left, right, {v0, v1, v2, v3, v4, v5, v6, v7}, end_flags}
  end

  defp mix_voice(
         {false, _, _, _, _, _, _, _, _, _} = voice,
         _mixer,
         _ram,
         _index,
         left,
         right,
         end_flags
       ),
       do: {left, right, voice, end_flags}

  defp mix_voice(
         {true, _, _, _, _, samples, sample_index, _, _, _} = voice,
         {pitch, volume_left, volume_right},
         ram,
         index,
         left,
         right,
         end_flags
       ) do
    sample = elem(samples, sample_index)
    {voice, ended?} = advance_render_voice(voice, pitch, ram)
    left = left + div(sample * volume_left, 128)
    right = right + div(sample * volume_right, 128)
    end_flags = if ended?, do: end_flags ||| 1 <<< index, else: end_flags
    {left, right, voice, end_flags}
  end

  defp advance_render_voice({_, _, _, _, _, _, _, phase, _, _} = voice, pitch, ram) do
    phase = phase + pitch
    steps = phase >>> 12
    voice = put_elem(voice, 7, phase &&& 0x0FFF)
    advance_render_samples(voice, steps, ram, false)
  end

  defp advance_render_samples(voice, 0, _ram, ended?), do: {voice, ended?}

  defp advance_render_samples(
         {false, _, _, _, _, _, _, _, _, _} = voice,
         _steps,
         _ram,
         ended?
       ),
       do: {voice, ended?}

  defp advance_render_samples(
         {true, block_address, loop_address, block_end?, block_loop?, samples, sample_index,
          phase, previous1, previous2},
         steps,
         ram,
         ended?
       ) do
    sample_index = sample_index + 1
    ended? = ended? or (sample_index >= 16 and block_end?)

    voice =
      if sample_index >= 16 do
        cond do
          block_end? and block_loop? ->
            {true, loop_address, loop_address, block_end?, block_loop?, samples, 0, phase,
             previous1, previous2}
            |> decode_render_block(ram)

          block_end? ->
            {false, block_address, loop_address, block_end?, block_loop?, samples, 15, phase,
             previous1, previous2}

          true ->
            {true, block_address + 9 &&& 0xFFFF, loop_address, block_end?, block_loop?, samples,
             0, phase, previous1, previous2}
            |> decode_render_block(ram)
        end
      else
        {true, block_address, loop_address, block_end?, block_loop?, samples, sample_index, phase,
         previous1, previous2}
      end

    advance_render_samples(voice, steps - 1, ram, ended?)
  end

  defp render_voices({v0, v1, v2, v3, v4, v5, v6, v7}),
    do:
      {render_voice(v0), render_voice(v1), render_voice(v2), render_voice(v3), render_voice(v4),
       render_voice(v5), render_voice(v6), render_voice(v7)}

  defp render_voice(voice),
    do:
      {voice.active?, voice.block_address, voice.loop_address, voice.block_end?,
       voice.block_loop?, voice.samples, voice.sample_index, voice.phase, voice.previous1,
       voice.previous2}

  defp store_voices({v0, v1, v2, v3, v4, v5, v6, v7}),
    do:
      {store_voice(v0), store_voice(v1), store_voice(v2), store_voice(v3), store_voice(v4),
       store_voice(v5), store_voice(v6), store_voice(v7)}

  defp store_voice(
         {active?, block_address, loop_address, block_end?, block_loop?, samples, sample_index,
          phase, previous1, previous2}
       ) do
    %{
      active?: active?,
      block_address: block_address,
      loop_address: loop_address,
      block_end?: block_end?,
      block_loop?: block_loop?,
      samples: samples,
      sample_index: sample_index,
      phase: phase,
      previous1: previous1,
      previous2: previous2
    }
  end

  defp decode_render_block(
         {active?, block_address, loop_address, _block_end?, _block_loop?, _samples, sample_index,
          phase, previous1, previous2},
         ram
       ) do
    {samples, previous1, previous2, block_end?, block_loop?} =
      decode_block_data(block_address, previous1, previous2, ram)

    {active?, block_address, loop_address, block_end?, block_loop?, samples, sample_index, phase,
     previous1, previous2}
  end

  defp decode_block(voice, ram) do
    {samples, previous1, previous2, block_end?, block_loop?} =
      decode_block_data(voice.block_address, voice.previous1, voice.previous2, ram)

    %{
      voice
      | samples: samples,
        previous1: previous1,
        previous2: previous2,
        block_end?: block_end?,
        block_loop?: block_loop?
    }
  end

  defp decode_block_data(block_address, previous1, previous2, ram) do
    header = ram_get(ram, block_address)
    range = header >>> 4
    filter = header >>> 2 &&& 0x03

    {samples, previous1, previous2} =
      decode_brr_bytes(ram, block_address, 0, range, filter, previous1, previous2, [])

    {samples |> Enum.reverse() |> List.to_tuple(), previous1, previous2, (header &&& 1) != 0,
     (header &&& 2) != 0}
  end

  defp decode_brr_bytes(_ram, _address, 8, _range, _filter, previous1, previous2, samples),
    do: {samples, previous1, previous2}

  defp decode_brr_bytes(
         ram,
         address,
         byte_index,
         range,
         filter,
         previous1,
         previous2,
         samples
       ) do
    byte = ram_get(ram, address + 1 + byte_index)
    high = decode_brr_nibble(byte >>> 4, range, filter, previous1, previous2)
    low = decode_brr_nibble(byte &&& 0x0F, range, filter, high, previous1)

    decode_brr_bytes(
      ram,
      address,
      byte_index + 1,
      range,
      filter,
      low,
      high,
      [low, high | samples]
    )
  end

  defp decode_brr_nibble(nibble, range, filter, previous1, previous2) do
    nibble = if nibble >= 8, do: nibble - 16, else: nibble

    sample =
      if range <= 12, do: (nibble <<< range) >>> 1, else: if(nibble < 0, do: -2048, else: 0)

    apply_filter(sample, filter, previous1, previous2) |> clip16()
  end

  defp apply_filter(sample, 0, _p1, _p2), do: sample
  defp apply_filter(sample, 1, p1, _p2), do: sample + p1 + (-p1 >>> 4)
  defp apply_filter(sample, 2, p1, p2), do: sample + p1 * 2 + ((-3 * p1) >>> 5) - p2 + (p2 >>> 4)

  defp apply_filter(sample, 3, p1, p2),
    do: sample + p1 * 2 + ((-13 * p1) >>> 6) - p2 + ((3 * p2) >>> 4)

  defp pitch(dsp, index),
    do: reg(dsp, index * 0x10 + 2) ||| (reg(dsp, index * 0x10 + 3) &&& 0x3F) <<< 8

  defp reg(dsp, address), do: :array.get(address, dsp.registers)
  defp ram_get(ram, address), do: :array.get(address &&& 0xFFFF, ram)
  defp ram_word(ram, address), do: ram_get(ram, address) ||| ram_get(ram, address + 1) <<< 8
  defp signed8(value) when value >= 0x80, do: value - 0x100
  defp signed8(value), do: value
  defp clip16(value), do: min(max(value, -32_768), 32_767)
end
