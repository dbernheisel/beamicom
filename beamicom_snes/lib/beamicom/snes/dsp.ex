defmodule Beamicom.SNES.DSP do
  @moduledoc "Native S-DSP voice mixer with BRR decoding and stereo volume control."

  import Bitwise

  @voice %{
    active?: false,
    block_address: 0,
    loop_address: 0,
    block_end?: false,
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
            key_on: dsp.key_on ||| value
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

    {dsp, pcm} =
      Enum.reduce(1..frames, {dsp, []}, fn _, {dsp, pcm} ->
        {left, right, dsp} = mix_sample(dsp, ram)
        {dsp, [<<left::signed-little-16, right::signed-little-16>> | pcm]}
      end)

    {dsp, pcm |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp apply_keys(dsp, ram) do
    voices =
      Enum.reduce(0..7, dsp.voices, fn index, voices ->
        voice = elem(voices, index)

        voice =
          cond do
            (dsp.key_off &&& 1 <<< index) != 0 -> %{voice | active?: false}
            (dsp.key_on &&& 1 <<< index) != 0 -> start_voice(dsp, ram, index)
            true -> voice
          end

        put_elem(voices, index, voice)
      end)

    %{dsp | voices: voices, key_on: 0}
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

  defp mix_sample(dsp, ram) do
    {left, right, voices, end_flags} =
      Enum.reduce(0..7, {0, 0, dsp.voices, dsp.end_flags}, fn index,
                                                              {left, right, voices, end_flags} ->
        voice = elem(voices, index)

        if voice.active? do
          sample = elem(voice.samples, voice.sample_index)
          voice = advance_voice(voice, pitch(dsp, index), ram)
          volume_left = signed8(reg(dsp, index * 0x10))
          volume_right = signed8(reg(dsp, index * 0x10 + 1))
          left = left + div(sample * volume_left, 128)
          right = right + div(sample * volume_right, 128)
          end_flags = if voice.active?, do: end_flags, else: end_flags ||| 1 <<< index
          {left, right, put_elem(voices, index, voice), end_flags}
        else
          {left, right, voices, end_flags}
        end
      end)

    muted? = (reg(dsp, 0x6C) &&& 0x40) != 0
    master_left = signed8(reg(dsp, 0x0C))
    master_right = signed8(reg(dsp, 0x1C))
    left = if muted?, do: 0, else: clip16(div(left * master_left, 128))
    right = if muted?, do: 0, else: clip16(div(right * master_right, 128))
    {left, right, %{dsp | voices: voices, end_flags: end_flags}}
  end

  defp advance_voice(voice, pitch, ram) do
    phase = voice.phase + pitch
    steps = phase >>> 12
    voice = %{voice | phase: phase &&& 0x0FFF}
    advance_samples(voice, steps, ram)
  end

  defp advance_samples(voice, 0, _ram), do: voice
  defp advance_samples(%{active?: false} = voice, _steps, _ram), do: voice

  defp advance_samples(voice, steps, ram) do
    voice = %{voice | sample_index: voice.sample_index + 1}

    voice =
      if voice.sample_index >= 16 do
        cond do
          voice.block_end? and voice.loop_address != 0 ->
            %{voice | block_address: voice.loop_address, sample_index: 0} |> decode_block(ram)

          voice.block_end? ->
            %{voice | active?: false, sample_index: 15}

          true ->
            %{voice | block_address: voice.block_address + 9 &&& 0xFFFF, sample_index: 0}
            |> decode_block(ram)
        end
      else
        voice
      end

    advance_samples(voice, steps - 1, ram)
  end

  defp decode_block(voice, ram) do
    header = ram_get(ram, voice.block_address)
    range = header >>> 4
    filter = header >>> 2 &&& 0x03

    {samples, previous1, previous2} =
      Enum.reduce(0..15, {[], voice.previous1, voice.previous2}, fn index,
                                                                    {samples, previous1,
                                                                     previous2} ->
        byte = ram_get(ram, voice.block_address + 1 + div(index, 2))
        nibble = if rem(index, 2) == 0, do: byte >>> 4, else: byte &&& 0x0F
        nibble = if nibble >= 8, do: nibble - 16, else: nibble

        sample =
          if range <= 12, do: (nibble <<< range) >>> 1, else: if(nibble < 0, do: -2048, else: 0)

        sample = apply_filter(sample, filter, previous1, previous2) |> clip16()
        {[sample | samples], sample, previous1}
      end)

    %{
      voice
      | samples: samples |> Enum.reverse() |> List.to_tuple(),
        previous1: previous1,
        previous2: previous2,
        block_end?: (header &&& 1) != 0
    }
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
