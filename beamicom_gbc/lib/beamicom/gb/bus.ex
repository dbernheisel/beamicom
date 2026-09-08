defmodule Beamicom.GB.Bus do
  @moduledoc """
  Minimal concrete Game Boy bus used by the SM83 bring-up core.

  Most addresses still use a test-only flat bring-up backing. CPU-visible
  interrupt, timer, and CGB speed ranges already use static function heads and
  compact projected scalar fields, so reads never synchronize a second copy in
  the array. Cartridge/VRAM/WRAM devices can replace the remaining range heads
  without introducing a protocol dispatch into CPU accesses.

  `tick/2` advances CPU T-cycles. Consequently an instruction scheduler calls
  it with four times the instruction's reported M-cycles in either speed mode;
  double speed changes the CPU-to-LCD relationship, not clocks per M-cycle.
  """

  import Bitwise

  @enforce_keys [:memory]
  defstruct memory: nil,
            divider: 0,
            tima: 0,
            tma: 0,
            tac: 0,
            timer_reload: 0,
            interrupt_flags: 0,
            ie: 0,
            control: 0

  @cgb 0x01
  @double_speed 0x02
  @prepare_speed 0x04
  @stop_wake 0x08

  @interrupt_vblank 0x01
  @interrupt_lcd_stat 0x02
  @interrupt_timer 0x04
  @interrupt_serial 0x08
  @interrupt_joypad 0x10

  @timer_periods {1024, 16, 64, 256}

  @compile {:inline,
            read: 2,
            write: 3,
            read_cycle: 2,
            write_cycle: 3,
            idle: 2,
            pending_interrupts: 1,
            double_speed?: 1,
            cgb?: 1,
            timer_input: 2}

  @type model :: :dmg | :cgb
  @type interrupt :: :vblank | :lcd_stat | :timer | :serial | :joypad

  @type t :: %__MODULE__{
          memory: :array.array(byte()),
          divider: 0..0xFFFF,
          tima: byte(),
          tma: byte(),
          tac: 0..7,
          timer_reload: 0..4,
          interrupt_flags: 0..0x1F,
          ie: byte(),
          control: byte()
        }

  @doc "Creates zero-filled memory and optionally loads bytes at address zero."
  @spec new(binary(), keyword()) :: t()
  def new(contents \\ <<>>, opts \\ [])
      when is_binary(contents) and byte_size(contents) <= 0x10000 do
    control = if Keyword.get(opts, :model, :dmg) == :cgb, do: @cgb, else: 0
    load(%__MODULE__{memory: :array.new(0x10000, default: 0), control: control}, 0, contents)
  end

  @doc "Loads a binary at an address without wrapping past `$FFFF`."
  @spec load(t(), 0..0xFFFF, binary()) :: t()
  def load(%__MODULE__{} = bus, address, contents)
      when address in 0x0000..0xFFFF and is_binary(contents) and
             address + byte_size(contents) <= 0x10000 do
    contents
    |> :binary.bin_to_list()
    |> Enum.with_index(address)
    |> Enum.reduce(bus, fn {value, offset}, bus -> load_byte(bus, offset, value) end)
  end

  defp load_byte(bus, 0xFF04, value), do: %{bus | divider: value <<< 8}
  defp load_byte(bus, 0xFF05, value), do: %{bus | tima: value}
  defp load_byte(bus, 0xFF06, value), do: %{bus | tma: value}
  defp load_byte(bus, 0xFF07, value), do: %{bus | tac: value &&& 0x07}
  defp load_byte(bus, 0xFF0F, value), do: %{bus | interrupt_flags: value &&& 0x1F}
  defp load_byte(bus, 0xFFFF, value), do: %{bus | ie: value}

  defp load_byte(%__MODULE__{memory: memory} = bus, address, value) do
    memory =
      :array.set(address, value, memory)

    %{bus | memory: memory}
  end

  @doc "Reads one byte, projecting implemented hardware registers."
  @spec read(t(), 0..0xFFFF) :: byte()
  def read(%__MODULE__{divider: divider}, 0xFF04), do: divider >>> 8
  def read(%__MODULE__{tima: tima}, 0xFF05), do: tima
  def read(%__MODULE__{tma: tma}, 0xFF06), do: tma
  def read(%__MODULE__{tac: tac}, 0xFF07), do: 0xF8 ||| tac
  def read(%__MODULE__{interrupt_flags: flags}, 0xFF0F), do: 0xE0 ||| flags
  def read(%__MODULE__{control: control}, 0xFF4D) when (control &&& @cgb) == 0, do: 0xFF

  def read(%__MODULE__{control: control}, 0xFF4D) do
    0x7E ||| if((control &&& @double_speed) != 0, do: 0x80, else: 0) |||
      if((control &&& @prepare_speed) != 0, do: 0x01, else: 0)
  end

  def read(%__MODULE__{ie: ie}, 0xFFFF), do: ie

  def read(%__MODULE__{memory: memory}, address) when address in 0x0000..0xFFFF,
    do: :array.get(address, memory)

  @doc "Writes one byte, applying timer and CGB register side effects."
  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{} = bus, 0xFF04, _value), do: reset_divider(bus)
  def write(%__MODULE__{} = bus, 0xFF05, value), do: %{bus | tima: value, timer_reload: 0}
  def write(%__MODULE__{} = bus, 0xFF06, value), do: %{bus | tma: value}

  def write(%__MODULE__{} = bus, 0xFF07, value) do
    old_input = timer_input(bus.divider, bus.tac)
    bus = %{bus | tac: value &&& 0x07}
    timer_control_edge(bus, old_input, timer_input(bus.divider, bus.tac))
  end

  def write(%__MODULE__{} = bus, 0xFF0F, value),
    do: %{bus | interrupt_flags: value &&& 0x1F}

  def write(%__MODULE__{control: control} = bus, 0xFF4D, value)
      when (control &&& @cgb) != 0 do
    control =
      if (value &&& 0x01) != 0,
        do: control ||| @prepare_speed,
        else: control &&& bxor(0xFF, @prepare_speed)

    %{bus | control: control}
  end

  def write(%__MODULE__{} = bus, 0xFF4D, _value), do: bus
  def write(%__MODULE__{} = bus, 0xFFFF, value), do: %{bus | ie: value}

  def write(%__MODULE__{memory: memory} = bus, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: %{bus | memory: :array.set(address, value, memory)}

  @doc false
  @spec read_cycle(t(), 0..0xFFFF) :: {byte(), t()}
  def read_cycle(%__MODULE__{} = bus, address), do: {read(bus, address), tick(bus, 4)}

  @doc false
  @spec write_cycle(t(), 0..0xFFFF, byte()) :: t()
  def write_cycle(%__MODULE__{} = bus, address, value),
    do: bus |> write(address, value) |> tick(4)

  @doc false
  @spec idle(t(), non_neg_integer()) :: t()
  def idle(%__MODULE__{} = bus, m_cycles), do: tick(bus, m_cycles * 4)

  @doc "Reads a little-endian 16-bit value, wrapping the second address."
  @spec read16(t(), 0..0xFFFF) :: 0..0xFFFF
  def read16(%__MODULE__{} = bus, address) when address in 0x0000..0xFFFF do
    low = read(bus, address)
    high = read(bus, rem(address + 1, 0x10000))
    low + high * 0x100
  end

  @doc "Writes a little-endian 16-bit value, wrapping the second address."
  @spec write16(t(), 0..0xFFFF, 0..0xFFFF) :: t()
  def write16(%__MODULE__{} = bus, address, value)
      when address in 0x0000..0xFFFF and value in 0x0000..0xFFFF do
    bus
    |> write(address, rem(value, 0x100))
    |> write(rem(address + 1, 0x10000), div(value, 0x100))
  end

  @doc "Returns enabled, requested interrupt bits in hardware priority order."
  @spec pending_interrupts(t()) :: 0..0x1F
  def pending_interrupts(%__MODULE__{ie: ie, interrupt_flags: flags}), do: ie &&& flags &&& 0x1F

  @doc "Requests an interrupt. Atom clauses compile to literal masks."
  @spec request_interrupt(t(), interrupt()) :: t()
  def request_interrupt(bus, :vblank), do: request_interrupt_mask(bus, @interrupt_vblank)
  def request_interrupt(bus, :lcd_stat), do: request_interrupt_mask(bus, @interrupt_lcd_stat)
  def request_interrupt(bus, :timer), do: request_interrupt_mask(bus, @interrupt_timer)
  def request_interrupt(bus, :serial), do: request_interrupt_mask(bus, @interrupt_serial)
  def request_interrupt(bus, :joypad), do: request_interrupt_mask(bus, @interrupt_joypad)

  @doc false
  @spec acknowledge_interrupt(t(), 1 | 2 | 4 | 8 | 16) :: t()
  def acknowledge_interrupt(%__MODULE__{interrupt_flags: flags} = bus, mask),
    do: %{bus | interrupt_flags: flags &&& bxor(0x1F, mask)}

  @doc "Signals the joypad transition that can leave STOP and requests joypad IRQ."
  @spec signal_joypad_edge(t()) :: t()
  def signal_joypad_edge(%__MODULE__{control: control} = bus) do
    request_interrupt_mask(%{bus | control: control ||| @stop_wake}, @interrupt_joypad)
  end

  @doc false
  @spec take_stop_wake(t()) :: {boolean(), t()}
  def take_stop_wake(%__MODULE__{control: control} = bus) when (control &&& @stop_wake) != 0,
    do: {true, %{bus | control: control &&& bxor(0xFF, @stop_wake)}}

  def take_stop_wake(%__MODULE__{} = bus), do: {false, bus}

  @doc "Returns whether this bus models CGB hardware."
  @spec cgb?(t()) :: boolean()
  def cgb?(%__MODULE__{control: control}), do: (control &&& @cgb) != 0

  @doc "Returns the active CGB CPU speed."
  @spec double_speed?(t()) :: boolean()
  def double_speed?(%__MODULE__{control: control}), do: (control &&& @double_speed) != 0

  @doc """
  Applies a STOP boundary.

  A prepared CGB switch toggles KEY1 immediately and leaves the CPU running.
  This bring-up model deliberately defers the hardware's stabilization delay
  to the future machine scheduler; timer clocks remain expressed in CPU
  T-cycles, so no timer-rate branch is needed here.
  """
  @spec stop(t()) :: {:stop | :speed_switch, t()}
  def stop(%__MODULE__{control: control} = bus)
      when (control &&& (@cgb ||| @prepare_speed)) == (@cgb ||| @prepare_speed) do
    clear = bxor(0xFF, @prepare_speed ||| @stop_wake)
    control = bxor(control, @double_speed) &&& clear
    {:speed_switch, reset_divider(%{bus | control: control})}
  end

  def stop(%__MODULE__{control: control} = bus),
    do: {:stop, %{bus | control: control &&& bxor(0xFF, @stop_wake)}}

  @doc "Advances the divider/timer by an exact count of CPU T-cycles."
  @spec tick(t(), non_neg_integer()) :: t()
  def tick(%__MODULE__{} = bus, 0), do: bus

  # The overwhelmingly common timer-off path avoids a per-clock loop.
  def tick(%__MODULE__{tac: tac, timer_reload: 0, divider: divider} = bus, clocks)
      when clocks > 0 and (tac &&& 0x04) == 0,
      do: %{bus | divider: divider + clocks &&& 0xFFFF}

  def tick(%__MODULE__{timer_reload: 0} = bus, clocks) when clocks > 0,
    do: tick_timer(bus, clocks)

  def tick(%__MODULE__{} = bus, clocks) when clocks > 0, do: tick_reload(bus, clocks)

  # Active timers jump directly between falling edges. Timer-off and the
  # usually much longer between-edge spans therefore stay batched.
  defp tick_timer(bus, 0), do: bus

  defp tick_timer(bus, clocks) do
    period = elem(@timer_periods, bus.tac &&& 0x03)
    until_edge = period - rem(bus.divider, period)

    if clocks < until_edge do
      %{bus | divider: bus.divider + clocks &&& 0xFFFF}
    else
      bus = %{bus | divider: bus.divider + until_edge &&& 0xFFFF}
      bus = increment_tima(bus)
      tick(bus, clocks - until_edge)
    end
  end

  defp tick_reload(bus, 0), do: bus

  defp tick_reload(bus, clocks) do
    bus = advance_reload(bus)
    old_input = timer_input(bus.divider, bus.tac)
    bus = %{bus | divider: bus.divider + 1 &&& 0xFFFF}
    bus = timer_control_edge(bus, old_input, timer_input(bus.divider, bus.tac))
    tick(bus, clocks - 1)
  end

  defp advance_reload(%__MODULE__{timer_reload: 0} = bus), do: bus

  defp advance_reload(%__MODULE__{timer_reload: 1, tma: tma} = bus) do
    request_interrupt_mask(%{bus | tima: tma, timer_reload: 0}, @interrupt_timer)
  end

  defp advance_reload(%__MODULE__{timer_reload: reload} = bus),
    do: %{bus | timer_reload: reload - 1}

  defp reset_divider(bus) do
    old_input = timer_input(bus.divider, bus.tac)
    bus = %{bus | divider: 0}
    timer_control_edge(bus, old_input, timer_input(0, bus.tac))
  end

  defp timer_control_edge(bus, 1, 0), do: increment_tima(bus)
  defp timer_control_edge(bus, _old, _new), do: bus

  defp increment_tima(%__MODULE__{timer_reload: reload} = bus) when reload != 0, do: bus
  defp increment_tima(%__MODULE__{tima: 0xFF} = bus), do: %{bus | tima: 0, timer_reload: 4}
  defp increment_tima(%__MODULE__{tima: tima} = bus), do: %{bus | tima: tima + 1}

  defp request_interrupt_mask(%__MODULE__{interrupt_flags: flags} = bus, mask),
    do: %{bus | interrupt_flags: flags ||| mask}

  defp timer_input(_divider, tac) when (tac &&& 0x04) == 0, do: 0
  defp timer_input(divider, tac) when (tac &&& 0x03) == 0, do: divider >>> 9 &&& 1
  defp timer_input(divider, tac) when (tac &&& 0x03) == 1, do: divider >>> 3 &&& 1
  defp timer_input(divider, tac) when (tac &&& 0x03) == 2, do: divider >>> 5 &&& 1
  defp timer_input(divider, _tac), do: divider >>> 7 &&& 1
end
