defmodule Beamicom.GBA.Timer do
  @moduledoc """
  Serializable state for one GBA hardware timer.

  Direct timers derive their visible counter from the shared master cycle and
  globally phased prescaler. Cascaded timers advance only when the preceding
  timer overflows. Deferred register writes and overflow generations let the
  scheduler discard obsolete events without storing callbacks in machine state.
  """

  import Bitwise

  @divisors {1, 64, 256, 1024}

  defstruct reload: 0,
            counter: 0,
            control: 0,
            last_cycle: 0,
            overflow_generation: 0,
            pending_reload: nil,
            reload_write_generation: 0,
            pending_control: nil,
            control_write_generation: 0

  def new, do: %__MODULE__{}

  def counter(%__MODULE__{} = timer, now) when is_integer(now) and now >= timer.last_cycle do
    timer = materialize(timer, now)
    timer.counter
  end

  def control(%__MODULE__{control: control}), do: control

  def enabled?(%__MODULE__{control: control}), do: bit?(control, 7)

  def count_up?(%__MODULE__{control: control}), do: bit?(control, 2)

  def irq_enabled?(%__MODULE__{control: control}), do: bit?(control, 6)

  def queue_reload_byte(%__MODULE__{} = timer, byte_index, byte)
      when byte_index in 0..1 and byte in 0x00..0xFF do
    reload = timer.pending_reload || timer.reload
    reload = put_byte(reload, byte_index, byte) &&& 0xFFFF
    generation = timer.reload_write_generation + 1

    {%{timer | pending_reload: reload, reload_write_generation: generation}, generation}
  end

  def apply_reload(%__MODULE__{} = timer, generation) do
    if generation == timer.reload_write_generation and not is_nil(timer.pending_reload) do
      {:applied, %{timer | reload: timer.pending_reload, pending_reload: nil}}
    else
      {:stale, timer}
    end
  end

  def queue_control(%__MODULE__{} = timer, index, byte)
      when index in 0..3 and byte in 0x00..0xFF do
    control = normalize_control(index, byte)
    generation = timer.control_write_generation + 1

    {%{timer | pending_control: control, control_write_generation: generation}, generation}
  end

  def apply_control(%__MODULE__{} = timer, generation, now)
      when is_integer(now) and now >= timer.last_cycle do
    if generation == timer.control_write_generation and not is_nil(timer.pending_control) do
      was_enabled? = enabled?(timer)
      timer = materialize(timer, now)
      control = timer.pending_control
      enabled? = bit?(control, 7)

      timer =
        if enabled? and not was_enabled?,
          do: %{timer | counter: timer.reload},
          else: timer

      {:applied,
       %{
         timer
         | control: control,
           last_cycle: now,
           overflow_generation: timer.overflow_generation + 1,
           pending_control: nil
       }}
    else
      {:stale, timer}
    end
  end

  def next_overflow_cycle(%__MODULE__{} = timer, now)
      when is_integer(now) and now >= timer.last_cycle do
    if enabled?(timer) and not count_up?(timer) do
      divisor = divisor(timer)
      remaining_ticks = 0x1_0000 - timer.counter
      (div(now, divisor) + remaining_ticks) * divisor
    end
  end

  def overflow_current?(%__MODULE__{} = timer, generation),
    do:
      enabled?(timer) and not count_up?(timer) and
        generation == timer.overflow_generation

  def overflow(%__MODULE__{} = timer, now) when is_integer(now) and now >= timer.last_cycle,
    do: %{timer | counter: timer.reload, last_cycle: now}

  def cascade_tick(%__MODULE__{counter: 0xFFFF} = timer, now),
    do: {:overflow, %{timer | counter: timer.reload, last_cycle: now}}

  def cascade_tick(%__MODULE__{} = timer, now),
    do: {:tick, %{timer | counter: timer.counter + 1, last_cycle: now}}

  defp materialize(%__MODULE__{} = timer, now) do
    if enabled?(timer) and not count_up?(timer) do
      divisor = divisor(timer)
      ticks = div(now, divisor) - div(timer.last_cycle, divisor)
      %{timer | counter: timer.counter + ticks &&& 0xFFFF, last_cycle: now}
    else
      %{timer | last_cycle: now}
    end
  end

  defp normalize_control(0, value), do: value &&& 0xC3
  defp normalize_control(_index, value), do: value &&& 0xC7

  defp divisor(%__MODULE__{control: control}), do: elem(@divisors, control &&& 0x3)

  defp put_byte(value, byte_index, byte) do
    shift = byte_index * 8
    (value &&& bnot(0xFF <<< shift)) ||| byte <<< shift
  end

  defp bit?(value, bit), do: (value &&& 1 <<< bit) != 0
end
