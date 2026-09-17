defmodule Beamicom.EI.Codes do
  @moduledoc false

  # Linux evdev gamepad codes from include/uapi/linux/input-event-codes.h:
  # https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
  @codes %{
    a: 0x130,
    b: 0x131,
    x: 0x133,
    y: 0x134,
    l: 0x136,
    r: 0x137,
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
