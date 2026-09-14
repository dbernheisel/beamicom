defmodule Beamicom.SNES.Bus.CPUAccess do
  @moduledoc false

  alias Beamicom.SNES.Bus

  defdelegate peek(bus, address), to: Bus
  defdelegate take_nmi(bus), to: Bus
  defdelegate irq_pending?(bus), to: Bus

  def read(bus, address), do: Bus.cpu_read(bus, address)
  def write(bus, address, value), do: Bus.cpu_write(bus, address, value)
  def idle(bus), do: Bus.cpu_idle(bus)
  def idle(bus, cycles), do: Bus.cpu_idle(bus, cycles)
  def flush(bus), do: Bus.flush_cpu_timing(bus)
  def flush_events(bus), do: Bus.flush_cpu_events(bus)
  def master_clocks(bus), do: Bus.cpu_master_clocks(bus)
end
