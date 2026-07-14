defmodule Beamicom.NES.Controllers do
  @moduledoc """
  Standard controller button encoding (spec §5.4). Button state is authoritative
  in the core; input sources (Scenic keyboard, Phoenix socket) call
  `Beamicom.NES.Console.set_buttons/3` with the pressed buttons, and the bus handles the
  shift-register mechanics.

  ## Sources
    * NESdev Wiki — standard controller: https://www.nesdev.org/wiki/Standard_controller
  """

  import Bitwise

  @bits %{
    a: 0x01,
    b: 0x02,
    select: 0x04,
    start: 0x08,
    up: 0x10,
    down: 0x20,
    left: 0x40,
    right: 0x80
  }

  @doc "Bitmask for a list of pressed button names, e.g. [:a, :start, :right]."
  def mask(buttons), do: Enum.reduce(buttons, 0, &(@bits[&1] ||| &2))
end
