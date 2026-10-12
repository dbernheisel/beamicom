defmodule Beamicom.GBA.APU do
  @moduledoc """
  Timer-driven Game Boy Advance PSG/Direct Sound state and host PCM renderer.

  FIFO transitions and PSG register writes retain their master-cycle
  timestamps. The host renderer consumes those transitions at frame
  boundaries, which keeps audio deterministic without scheduling a separate
  event for every host sample.
  """

  import Bitwise

  alias __MODULE__.PSG

  @blank_psg_registers :binary.copy(<<0>>, 32)
  @blank_wave_ram :binary.copy(<<0>>, 32)

  defstruct soundcnt_l: 0,
            soundcnt_h: 0,
            soundcnt_x: 0,
            soundbias: 0x0200,
            fifo_a: <<>>,
            fifo_b: <<>>,
            sample_a: 0,
            sample_b: 0,
            psg_registers: @blank_psg_registers,
            wave_ram: @blank_wave_ram,
            psg_events: [],
            psg: PSG.new(),
            events: [],
            render_cycle: 0,
            render_left: 0,
            render_right: 0

  @doc "Creates powered-on audio state at a master-cycle boundary."
  def new(cycle \\ 0) when is_integer(cycle) and cycle >= 0,
    do: %__MODULE__{render_cycle: cycle, psg: PSG.new(cycle)}

  @doc "Resets sound registers without discarding already timestamped host audio."
  def reset_registers(%__MODULE__{} = apu, cycle) when is_integer(cycle) and cycle >= 0 do
    %{
      apu
      | soundcnt_l: 0,
        soundcnt_h: 0,
        soundcnt_x: 0,
        soundbias: 0x0200,
        fifo_a: <<>>,
        fifo_b: <<>>,
        sample_a: 0,
        sample_b: 0,
        psg_registers: @blank_psg_registers
    }
    |> record_psg_write(0x84, 0, cycle)
    |> record_mix(cycle)
  end

  @doc "Reads one implemented sound-control byte."
  def register(%__MODULE__{} = apu, offset) when offset in 0x60..0x7F do
    value = :binary.at(apu.psg_registers, offset - 0x60)

    case offset do
      offset when offset in [0x62, 0x68] -> value &&& 0xC0
      offset when offset in [0x65, 0x6D, 0x75, 0x7D] -> value &&& 0x40
      offset when offset in [0x60, 0x63, 0x69, 0x70, 0x73, 0x79, 0x7C] -> value
      _unused_or_write_only -> 0
    end
  end

  def register(%__MODULE__{} = apu, offset) when offset in 0x80..0x89 do
    case offset do
      0x80 -> apu.soundcnt_l &&& 0xFF
      0x81 -> apu.soundcnt_l >>> 8
      0x82 -> apu.soundcnt_h &&& 0xFF
      0x83 -> apu.soundcnt_h >>> 8
      0x84 -> apu.soundcnt_x ||| pending_psg_status(apu)
      0x88 -> apu.soundbias &&& 0xFF
      0x89 -> apu.soundbias >>> 8
      _unused -> 0
    end
  end

  def register(%__MODULE__{} = apu, offset) when offset in 0x90..0x9F do
    bank = bxor(:binary.at(apu.psg_registers, 0x10) >>> 6 &&& 1, 1)
    :binary.at(apu.wave_ram, bank * 16 + offset - 0x90)
  end

  def register(%__MODULE__{}, offset) when offset in 0x60..0x9F, do: 0

  @doc "Writes one implemented sound-control byte."
  def put_register(%__MODULE__{} = apu, offset, byte, cycle)
      when offset in 0x60..0x7F and byte in 0x00..0xFF do
    if master_enabled?(apu) do
      registers = put_byte(apu.psg_registers, offset - 0x60, byte)
      %{apu | psg_registers: registers} |> record_psg_write(offset, byte, cycle)
    else
      apu
    end
  end

  def put_register(%__MODULE__{} = apu, 0x80, byte, cycle) do
    if master_enabled?(apu) do
      %{apu | soundcnt_l: (apu.soundcnt_l &&& 0xFF00) ||| (byte &&& 0x77)}
      |> record_psg_write(0x80, byte, cycle)
    else
      apu
    end
  end

  def put_register(%__MODULE__{} = apu, 0x81, byte, cycle) do
    if master_enabled?(apu) do
      %{apu | soundcnt_l: (apu.soundcnt_l &&& 0x00FF) ||| byte <<< 8}
      |> record_psg_write(0x81, byte, cycle)
    else
      apu
    end
  end

  def put_register(%__MODULE__{} = apu, 0x82, byte, cycle) do
    apu
    |> Map.put(:soundcnt_h, (apu.soundcnt_h &&& 0x7F00) ||| (byte &&& 0x0F))
    |> record_psg_write(0x82, byte, cycle)
    |> record_mix(cycle)
  end

  def put_register(%__MODULE__{} = apu, 0x83, byte, cycle) do
    reset_a? = bit?(byte, 3)
    reset_b? = bit?(byte, 7)
    soundcnt_h = (apu.soundcnt_h &&& 0x00FF) ||| (byte &&& 0x77) <<< 8

    apu =
      %{apu | soundcnt_h: soundcnt_h}
      |> maybe_reset_fifo(:a, reset_a?)
      |> maybe_reset_fifo(:b, reset_b?)
      |> record_psg_write(0x83, byte, cycle)

    record_mix(apu, cycle)
  end

  def put_register(%__MODULE__{} = apu, 0x84, byte, cycle) do
    enabled? = bit?(byte, 7)

    apu =
      if enabled? do
        %{apu | soundcnt_x: 0x80}
      else
        %{
          apu
          | soundcnt_l: 0,
            soundcnt_x: 0,
            sample_a: 0,
            sample_b: 0,
            psg_registers: @blank_psg_registers
        }
      end

    apu = record_psg_write(apu, 0x84, byte, cycle)
    record_mix(apu, cycle)
  end

  def put_register(%__MODULE__{} = apu, 0x88, byte, _cycle),
    do: %{apu | soundbias: (apu.soundbias &&& 0x3F00) ||| byte}

  def put_register(%__MODULE__{} = apu, 0x89, byte, _cycle),
    do: %{apu | soundbias: (apu.soundbias &&& 0x00FF) ||| (byte &&& 0x3F) <<< 8}

  def put_register(%__MODULE__{} = apu, offset, byte, cycle)
      when offset in 0x90..0x9F and byte in 0x00..0xFF do
    bank = bxor(:binary.at(apu.psg_registers, 0x10) >>> 6 &&& 1, 1)
    wave_ram = put_byte(apu.wave_ram, bank * 16 + offset - 0x90, byte)
    %{apu | wave_ram: wave_ram} |> record_psg_write(offset, byte, cycle)
  end

  def put_register(%__MODULE__{} = apu, offset, _byte, _cycle) when offset in 0x60..0x9F,
    do: apu

  @doc "Pushes one byte into Direct Sound FIFO A or B."
  def put_fifo(%__MODULE__{} = apu, channel, byte)
      when channel in [:a, :b] and byte in 0x00..0xFF do
    field = fifo_field(channel)
    fifo = Map.fetch!(apu, field)
    fifo = if byte_size(fifo) < 32, do: fifo <> <<byte>>, else: fifo
    Map.put(apu, field, fifo)
  end

  @doc false
  def put_fifo_binary(%__MODULE__{} = apu, channel, samples)
      when channel in [:a, :b] and is_binary(samples) do
    field = fifo_field(channel)
    fifo = Map.fetch!(apu, field)
    available = 32 - byte_size(fifo)
    Map.put(apu, field, fifo <> binary_part(samples, 0, min(available, byte_size(samples))))
  end

  @doc "Returns the number of queued sample bytes in a Direct Sound FIFO."
  def fifo_size(%__MODULE__{} = apu, channel) when channel in [:a, :b],
    do: byte_size(Map.fetch!(apu, fifo_field(channel)))

  @doc "Advances the Direct Sound channels clocked by a timer overflow."
  def timer_overflow(%__MODULE__{} = apu, timer, cycle)
      when timer in 0..1 and is_integer(cycle) and cycle >= 0 do
    if master_enabled?(apu) do
      {apu, refills} = clock_channel(apu, :a, timer, [])
      {apu, refills} = clock_channel(apu, :b, timer, refills)
      {record_mix(apu, cycle), Enum.reverse(refills)}
    else
      {apu, []}
    end
  end

  @doc "Renders and drains timestamped audio transitions through `end_cycle`."
  def render(%__MODULE__{} = apu, end_cycle, phase, clock_rate, sample_rate)
      when is_integer(end_cycle) and end_cycle >= apu.render_cycle and is_integer(phase) and
             phase >= 0 and is_integer(clock_rate) and clock_rate > 0 and
             is_integer(sample_rate) and sample_rate > 0 do
    duration = end_cycle - apu.render_cycle
    total = phase + duration * sample_rate
    sample_count = div(total, clock_rate)
    next_phase = rem(total, clock_rate)
    chronological = Enum.reverse(apu.events)

    {ready, future} =
      Enum.split_while(chronological, fn {cycle, _left, _right} -> cycle <= end_cycle end)

    {psg_ready, psg_future} =
      apu.psg_events
      |> Enum.reverse()
      |> Enum.split_while(fn {cycle, _offset, _value} -> cycle <= end_cycle end)

    {pcm, remaining, psg_remaining, left, right, psg} =
      if psg_ready == [] and PSG.status(apu.psg) == 0 do
        {pcm, remaining, left, right} =
          render_direct_samples(
            sample_count,
            apu.render_cycle,
            phase,
            clock_rate,
            sample_rate,
            ready,
            apu.render_left,
            apu.render_right,
            []
          )

        {pcm, remaining, [], left, right, PSG.advance_to(apu.psg, end_cycle)}
      else
        render_samples(
          sample_count,
          apu.render_cycle,
          phase,
          clock_rate,
          sample_rate,
          ready,
          psg_ready,
          apu.render_left,
          apu.render_right,
          apu.psg,
          []
        )
      end

    {left, right} = apply_events_through(remaining, end_cycle, left, right)
    psg = apply_psg_events_through(psg_remaining, end_cycle, psg)

    apu = %{
      apu
      | events: Enum.reverse(future),
        psg_events: Enum.reverse(psg_future),
        psg: psg,
        render_cycle: end_cycle,
        render_left: left,
        render_right: right
    }

    {apu, sample_count, IO.iodata_to_binary(Enum.reverse(pcm)), next_phase}
  end

  defp render_samples(
         0,
         _start,
         _phase,
         _clock,
         _rate,
         events,
         psg_events,
         left,
         right,
         psg,
         pcm
       ),
       do: {pcm, events, psg_events, left, right, psg}

  defp render_samples(
         count,
         start,
         phase,
         clock,
         rate,
         events,
         psg_events,
         left,
         right,
         psg,
         pcm
       ) do
    render_samples(
      1,
      count,
      start,
      phase,
      clock,
      rate,
      events,
      psg_events,
      left,
      right,
      psg,
      pcm
    )
  end

  defp render_samples(
         index,
         count,
         start,
         phase,
         clock,
         rate,
         events,
         psg_events,
         left,
         right,
         psg,
         pcm
       )
       when index <= count do
    offset = div(index * clock - phase + rate - 1, rate)
    cycle = start + offset
    {events, left, right} = apply_events_at_sample(events, cycle, left, right)
    {psg_events, psg} = apply_psg_events_at_sample(psg_events, cycle, psg)
    {psg_left, psg_right} = PSG.mix(psg)

    sample =
      <<clamp(left + psg_left)::signed-little-16, clamp(right + psg_right)::signed-little-16>>

    render_samples(
      index + 1,
      count,
      start,
      phase,
      clock,
      rate,
      events,
      psg_events,
      left,
      right,
      psg,
      [sample | pcm]
    )
  end

  defp render_samples(
         _index,
         _count,
         _start,
         _phase,
         _clock,
         _rate,
         events,
         psg_events,
         left,
         right,
         psg,
         pcm
       ),
       do: {pcm, events, psg_events, left, right, psg}

  defp render_direct_samples(0, _start, _phase, _clock, _rate, events, left, right, pcm),
    do: {pcm, events, left, right}

  defp render_direct_samples(count, start, phase, clock, rate, events, left, right, pcm) do
    render_direct_samples(1, count, start, phase, clock, rate, events, left, right, pcm)
  end

  defp render_direct_samples(index, count, start, phase, clock, rate, events, left, right, pcm)
       when index <= count do
    offset = div(index * clock - phase + rate - 1, rate)
    cycle = start + offset
    {events, left, right} = apply_events_at_sample(events, cycle, left, right)
    sample = <<clamp(left)::signed-little-16, clamp(right)::signed-little-16>>

    render_direct_samples(
      index + 1,
      count,
      start,
      phase,
      clock,
      rate,
      events,
      left,
      right,
      [sample | pcm]
    )
  end

  defp render_direct_samples(
         _index,
         _count,
         _start,
         _phase,
         _clock,
         _rate,
         events,
         left,
         right,
         pcm
       ),
       do: {pcm, events, left, right}

  defp apply_events_at_sample([{cycle, left, right} | rest], sample_cycle, _old_l, _old_r)
       when cycle <= sample_cycle,
       do: apply_events_at_sample(rest, sample_cycle, left, right)

  defp apply_events_at_sample(events, _sample_cycle, left, right),
    do: {events, left, right}

  defp apply_events_through([{cycle, left, right} | rest], end_cycle, _old_l, _old_r)
       when cycle <= end_cycle,
       do: apply_events_through(rest, end_cycle, left, right)

  defp apply_events_through(_events, _end_cycle, left, right), do: {left, right}

  defp apply_psg_events_at_sample(
         [{cycle, offset, value} | rest],
         sample_cycle,
         psg
       )
       when cycle <= sample_cycle do
    psg = psg |> PSG.advance_to(cycle) |> PSG.write(offset, value)
    apply_psg_events_at_sample(rest, sample_cycle, psg)
  end

  defp apply_psg_events_at_sample(events, sample_cycle, psg),
    do: {events, PSG.advance_to(psg, sample_cycle)}

  defp apply_psg_events_through([{cycle, offset, value} | rest], end_cycle, psg)
       when cycle <= end_cycle do
    psg = psg |> PSG.advance_to(cycle) |> PSG.write(offset, value)
    apply_psg_events_through(rest, end_cycle, psg)
  end

  defp apply_psg_events_through(_events, end_cycle, psg), do: PSG.advance_to(psg, end_cycle)

  defp pending_psg_status(%{psg_events: []} = apu), do: PSG.status(apu.psg)

  defp pending_psg_status(apu) do
    psg =
      apu.psg_events
      |> Enum.reverse()
      |> Enum.reduce(apu.psg, fn {cycle, offset, value}, psg ->
        psg |> PSG.advance_to(cycle) |> PSG.write(offset, value)
      end)

    PSG.status(psg)
  end

  defp clock_channel(apu, channel, timer, refills) do
    if channel_timer(apu, channel) == timer do
      fifo_field = fifo_field(channel)
      sample_field = sample_field(channel)
      {sample, fifo} = pop_fifo(Map.fetch!(apu, fifo_field))
      apu = apu |> Map.put(fifo_field, fifo) |> Map.put(sample_field, sample)
      refills = if byte_size(fifo) <= 16, do: [channel | refills], else: refills
      {apu, refills}
    else
      {apu, refills}
    end
  end

  defp pop_fifo(<<sample, rest::binary>>), do: {signed_byte(sample), rest}
  defp pop_fifo(<<>>), do: {0, <<>>}

  defp record_mix(apu, cycle) do
    {left, right} = mix(apu)

    case apu.events do
      [{^cycle, ^left, ^right} | _rest] -> apu
      _events -> %{apu | events: [{cycle, left, right} | apu.events]}
    end
  end

  defp record_psg_write(apu, offset, value, cycle) do
    if apu.psg.master or offset == 0x84 or offset in 0x90..0x9F or apu.psg_events != [] do
      %{apu | psg_events: [{cycle, offset, value} | apu.psg_events]}
    else
      apu
    end
  end

  defp mix(apu) do
    if master_enabled?(apu) do
      a = apu.sample_a * if(bit?(apu.soundcnt_h, 2), do: 128, else: 64)
      b = apu.sample_b * if(bit?(apu.soundcnt_h, 3), do: 128, else: 64)
      right = route(a, apu.soundcnt_h, 8) + route(b, apu.soundcnt_h, 12)
      left = route(a, apu.soundcnt_h, 9) + route(b, apu.soundcnt_h, 13)
      {clamp(left), clamp(right)}
    else
      {0, 0}
    end
  end

  defp route(sample, control, bit), do: if(bit?(control, bit), do: sample, else: 0)

  defp channel_timer(apu, :a), do: if(bit?(apu.soundcnt_h, 10), do: 1, else: 0)
  defp channel_timer(apu, :b), do: if(bit?(apu.soundcnt_h, 14), do: 1, else: 0)

  defp maybe_reset_fifo(apu, _channel, false), do: apu

  defp maybe_reset_fifo(apu, channel, true) do
    apu
    |> Map.put(fifo_field(channel), <<>>)
    |> Map.put(sample_field(channel), 0)
  end

  defp fifo_field(:a), do: :fifo_a
  defp fifo_field(:b), do: :fifo_b
  defp sample_field(:a), do: :sample_a
  defp sample_field(:b), do: :sample_b

  defp master_enabled?(apu), do: bit?(apu.soundcnt_x, 7)
  defp signed_byte(byte) when byte >= 0x80, do: byte - 0x100
  defp signed_byte(byte), do: byte
  defp clamp(sample), do: sample |> max(-32_768) |> min(32_767)
  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0

  defp put_byte(binary, offset, value) do
    <<prefix::binary-size(^offset), _old, suffix::binary>> = binary
    prefix <> <<value>> <> suffix
  end
end
