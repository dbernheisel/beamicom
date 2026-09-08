defmodule Beamicom.GB do
  @moduledoc """
  The dependency-free Game Boy and Game Boy Color emulator core.

  The core is being built from the cartridge inward. `Beamicom.GB.Cartridge`
  loads no-MBC cartridges and exposes their ROM and external-RAM address
  windows. `Beamicom.GB.CPU` implements the SM83 instruction set, interrupt
  control, and cycle-ordered accesses against a separate concrete bus.
  `Beamicom.GB.Bus` projects interrupt, timer, and CGB speed registers over a
  flat-memory bring-up backing store. Header inspection is available through
  `Beamicom.GB.Header` independently of mapper support.
  """
end
