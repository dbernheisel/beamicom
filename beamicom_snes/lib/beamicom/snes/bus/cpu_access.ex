defmodule Beamicom.SNES.Bus.CPUAccess do
  @moduledoc false

  # These are macros because every emulated instruction performs several bus
  # operations. Keeping this naming shim out of the runtime call chain saves a
  # full BEAM dispatch on each fetch, data access, and internal cycle.
  defmacro peek(bus, address),
    do: quote(do: Beamicom.SNES.Bus.peek(unquote(bus), unquote(address)))

  defmacro take_nmi(bus),
    do: quote(do: Beamicom.SNES.Bus.take_nmi(unquote(bus)))

  defmacro irq_pending?(bus),
    do: quote(do: Beamicom.SNES.Bus.irq_pending?(unquote(bus)))

  defmacro read(bus, address),
    do: quote(do: Beamicom.SNES.Bus.cpu_read(unquote(bus), unquote(address)))

  defmacro write(bus, address, value),
    do: quote(do: Beamicom.SNES.Bus.cpu_write(unquote(bus), unquote(address), unquote(value)))

  defmacro idle(bus) do
    quote do
      cpu_bus = unquote(bus)
      clocks = 6
      {clock_counters, _open_bus} = cpu_bus.runtime
      :ok = :counters.add(clock_counters, 1, clocks)
      {cpu_bus, clocks}
    end
  end

  defmacro idle(bus, cycles) do
    quote do
      cpu_bus = unquote(bus)
      clocks = unquote(cycles) * 6
      {clock_counters, _open_bus} = cpu_bus.runtime
      :ok = :counters.add(clock_counters, 1, clocks)
      {cpu_bus, clocks}
    end
  end

  defmacro flush(bus),
    do: quote(do: Beamicom.SNES.Bus.flush_cpu_timing(unquote(bus)))

  defmacro flush_events(bus),
    do: quote(do: Beamicom.SNES.Bus.flush_cpu_events(unquote(bus)))

  defmacro master_clocks(bus),
    do: quote(do: Beamicom.SNES.Bus.cpu_master_clocks(unquote(bus)))
end
