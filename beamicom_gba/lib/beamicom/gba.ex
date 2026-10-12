defmodule Beamicom.GBA do
  @moduledoc """
  A deterministic Game Boy Advance emulator core written in Elixir.

  The scalar implementation owns ARM7TDMI execution, memory, MMIO, and device
  timing. Optional Nx modules accelerate bounded rendering work without
  becoming a correctness dependency.

  The current milestone boots ARM and Thumb diagnostics, models the main memory
  regions plus DMA, timers, and interrupts, and renders tiled mode 0 and bitmap
  mode 3. It is not yet a general-purpose commercial-game compatibility claim.
  """
end
