defmodule Beamicom.NES.Console do
  @moduledoc """
  Ties the core together (spec §4): a `%CPU{}`, the `%Bus{}` (RAM/WRAM/cart), and
  the `%PPU{}` living inside the bus. `step/1` runs one CPU instruction, advances
  the PPU by 3 dots per CPU cycle (spec §3), then services an NMI if the PPU
  raised one this step.

  This is the "catch-up" scheme: register accesses happen at instruction
  boundaries rather than mid-instruction. It is accurate enough for the coarse
  vbl/NMI behaviour; the dot-exact suppression cases (spec §5.2 item 3) will need
  finer interleaving.

  ## Sources
    * NESdev Wiki — clock timing, 3 PPU dots per CPU cycle: https://www.nesdev.org/wiki/Cycle_reference_chart
    * NESdev Wiki — NMI: https://www.nesdev.org/wiki/NMI
  """

  alias Beamicom.NES.{Cart, Bus, CPU, PPU}

  defstruct [:cpu, :bus]

  @doc "Load an iNES ROM and cold-boot the console."
  def load(path) do
    {:ok, cart} = Cart.parse(File.read!(path))
    bus = Bus.new(cart, PPU.new(cart.chr_rom, cart.mirroring))
    %__MODULE__{cpu: CPU.reset(bus), bus: bus}
  end

  @doc "Run one CPU instruction; the CPU ticks the PPU cycle-by-cycle and delivers any NMI."
  def step(%__MODULE__{cpu: cpu, bus: bus}) do
    {cpu, bus} = CPU.step(cpu, bus)
    %__MODULE__{cpu: cpu, bus: bus}
  end

  @doc "Set controller `port` (1 or 2) to the pressed buttons, e.g. [:a, :start]."
  def set_buttons(%__MODULE__{bus: bus} = console, port, buttons),
    do: %{console | bus: Bus.set_buttons(bus, port, Beamicom.NES.Controllers.mask(buttons))}
end
