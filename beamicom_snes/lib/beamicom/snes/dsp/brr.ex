defmodule Beamicom.SNES.DSP.BRR do
  @moduledoc """
  Clock-local BRR address, fetch, and four-sample decode state.

  The authentic pipeline caches the header and first BRR data byte during
  voice stage 3, then reads the following byte and decodes four nibbles during
  stage 4. This split is required for intervening APU RAM writes to remain
  visible. The stage ordering and arithmetic follow the independently derived
  [ares S-DSP BRR pipeline](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/brr.cpp).
  """

  import Bitwise

  alias Beamicom.SNES.APU.RAM
  alias Beamicom.SNES.DSP.Arithmetic

  defstruct bank: 0,
            latched_bank: 0,
            source: 0,
            directory_address: 0,
            next_address: 0,
            header: 0,
            byte: 0

  def new, do: %__MODULE__{}

  def write_directory(%__MODULE__{} = brr, bank), do: %{brr | bank: bank &&& 0xFF}

  def latch_directory(%__MODULE__{} = brr), do: %{brr | latched_bank: brr.bank}

  def directory_stage(%__MODULE__{} = brr, source) do
    source = source &&& 0xFF
    address = brr.latched_bank <<< 8 ||| brr.source <<< 2
    %{brr | directory_address: address &&& 0xFFFF, source: source &&& 0xFF}
  end

  def pointer_stage(%__MODULE__{} = brr, ram, keyon_delay) do
    address = brr.directory_address + if(keyon_delay == 0, do: 2, else: 0)
    %{brr | next_address: ram_word(ram, address)}
  end

  def fetch(%__MODULE__{} = brr, voice, ram) do
    %{
      brr
      | byte: ram_get(ram, voice.brr_address + voice.brr_offset),
        header: ram_get(ram, voice.brr_address)
    }
  end

  @doc false
  def fetch_values(%__MODULE__{}, voice, ram) do
    {ram_get(ram, voice.brr_address + voice.brr_offset), ram_get(ram, voice.brr_address)}
  end

  @doc false
  def finish_voice_window(
        %__MODULE__{} = brr,
        byte,
        header,
        source,
        pointer_keyon_delay,
        ram
      ) do
    directory_address = brr.latched_bank <<< 8 ||| brr.source <<< 2
    pointer_address = directory_address + if(pointer_keyon_delay == 0, do: 2, else: 0)

    %{
      brr
      | source: source &&& 0xFF,
        directory_address: directory_address &&& 0xFFFF,
        next_address: ram_word(ram, pointer_address),
        header: header,
        byte: byte
    }
  end

  def decode(%__MODULE__{} = brr, voice, ram) do
    {brr, buffer, buffer_offset, brr_address, brr_offset, looped?, ended?} =
      decode_state(
        brr,
        voice.buffer,
        voice.buffer_offset,
        voice.brr_address,
        voice.brr_offset,
        ram
      )

    voice = %{
      voice
      | buffer: buffer,
        buffer_offset: buffer_offset,
        brr_address: brr_address,
        brr_offset: brr_offset,
        looped?: looped?
    }

    {brr, voice, ended?}
  end

  @doc false
  def decode_state(
        %__MODULE__{byte: byte, header: header, next_address: next_address} = brr,
        buffer,
        buffer_offset,
        brr_address,
        brr_offset,
        ram
      ) do
    {buffer, buffer_offset, brr_address, brr_offset, looped?, ended?} =
      decode_values(
        byte,
        header,
        next_address,
        buffer,
        buffer_offset,
        brr_address,
        brr_offset,
        ram
      )

    {brr, buffer, buffer_offset, brr_address, brr_offset, looped?, ended?}
  end

  @doc false
  def decode_values(
        byte,
        header,
        next_address,
        buffer,
        buffer_offset,
        brr_address,
        brr_offset,
        ram
      ) do
    nybbles = byte <<< 8 ||| ram_get(ram, brr_address + brr_offset + 1)

    range = header >>> 4
    filter = header >>> 2 &&& 0x03

    {buffer, buffer_offset, nybbles} =
      decode_and_store(buffer, buffer_offset, nybbles, range, filter)

    {buffer, buffer_offset, nybbles} =
      decode_and_store(buffer, buffer_offset, nybbles, range, filter)

    {buffer, buffer_offset, nybbles} =
      decode_and_store(buffer, buffer_offset, nybbles, range, filter)

    {buffer, buffer_offset, _nybbles} =
      decode_and_store(buffer, buffer_offset, nybbles, range, filter)

    next_offset = brr_offset + 2
    ended? = next_offset >= 9 and (header &&& 0x01) != 0

    {brr_address, brr_offset, looped?} =
      if next_offset >= 9 do
        address = if ended?, do: next_address, else: brr_address + 9
        {address &&& 0xFFFF, 1, ended?}
      else
        {brr_address, next_offset, false}
      end

    {buffer, buffer_offset, brr_address, brr_offset, looped?, ended?}
  end

  def decode_nibble(nibble, range, filter, previous1, previous2) do
    nibble = if (nibble &&& 0x08) == 0, do: nibble &&& 0x0F, else: (nibble &&& 0x0F) - 16

    sample =
      if range <= 12,
        do: Arithmetic.shift_right(nibble <<< range, 1),
        else: nibble &&& -0x800

    previous2 = Arithmetic.shift_right(previous2, 1)

    sample
    |> apply_filter(filter, previous1, previous2)
    |> Arithmetic.clamp16()
    |> Kernel.*(2)
    |> Arithmetic.signed16()
  end

  def end_without_loop?(%__MODULE__{} = brr), do: (brr.header &&& 0x03) == 0x01

  defp previous_samples(buffer, buffer_offset) do
    previous1 = if buffer_offset == 0, do: 11, else: buffer_offset - 1

    previous2 =
      case buffer_offset do
        0 -> 10
        1 -> 11
        offset -> offset - 2
      end

    {elem(buffer, previous1), elem(buffer, previous2)}
  end

  defp decode_and_store(buffer, buffer_offset, nybbles, range, filter) do
    nibble = nybbles >>> 12 &&& 0x0F
    {previous1, previous2} = previous_samples(buffer, buffer_offset)
    sample = decode_nibble(nibble, range, filter, previous1, previous2)
    buffer = put_elem(buffer, buffer_offset, sample)
    buffer_offset = if buffer_offset == 11, do: 0, else: buffer_offset + 1
    {buffer, buffer_offset, nybbles <<< 4}
  end

  defp apply_filter(sample, 0, _previous1, _previous2), do: sample

  defp apply_filter(sample, 1, previous1, _previous2),
    do:
      sample + Arithmetic.shift_right(previous1, 1) +
        Arithmetic.shift_right(-previous1, 5)

  defp apply_filter(sample, 2, previous1, previous2),
    do:
      sample + previous1 - previous2 + Arithmetic.shift_right(previous2, 4) +
        Arithmetic.shift_right(-3 * previous1, 6)

  defp apply_filter(sample, 3, previous1, previous2),
    do:
      sample + previous1 - previous2 + Arithmetic.shift_right(-13 * previous1, 7) +
        Arithmetic.shift_right(3 * previous2, 4)

  defp ram_get(ram, address), do: RAM.get(ram, address)
  defp ram_word(ram, address), do: ram_get(ram, address) ||| ram_get(ram, address + 1) <<< 8
end
