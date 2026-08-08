defmodule Beamicom.EI.Codes do
  @moduledoc false
  @codes %{
    a: 0x130,
    b: 0x131,
    select: 0x13A,
    start: 0x13B,
    up: 0x220,
    down: 0x221,
    left: 0x222,
    right: 0x223
  }
  @buttons Map.keys(@codes)
  def buttons, do: @buttons
  def code(button), do: Map.fetch(@codes, button)

  def button(code),
    do: Enum.find_value(@codes, fn {button, value} -> if value == code, do: button end)
end
