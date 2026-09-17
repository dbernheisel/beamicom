defmodule Beamicom.SNES.SPC700HaltTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.SPC700

  test "SLEEP and STOP enter distinct halt states after their bus sequence" do
    sleeping = SPC700.new(spc_ram([{0, 0xEF}]), 0) |> SPC700.run(1)
    stopped = SPC700.new(spc_ram([{0, 0xFF}]), 0) |> SPC700.run(1)

    assert Map.get(sleeping, :sleeping?)
    refute sleeping.stopped?
    refute Map.get(stopped, :sleeping?)
    assert stopped.stopped?
    assert {sleeping.pc, sleeping.cycles} == {1, 7}
    assert {stopped.pc, stopped.cycles} == {1, 7}
  end

  test "wake resumes SLEEP but leaves STOP latched" do
    sleeping = SPC700.new(spc_ram([{0, 0xEF}, {1, 0xE8}, {2, 0x42}]), 0) |> SPC700.run(1)

    resumed = sleeping |> SPC700.wake() |> SPC700.run(7)

    refute resumed.sleeping?
    refute resumed.stopped?
    assert resumed.a == 0x42
    assert resumed.pc == 3

    stopped = SPC700.new(spc_ram([{0, 0xFF}, {1, 0xE8}, {2, 0x42}]), 0) |> SPC700.run(1)
    still_stopped = stopped |> SPC700.wake() |> SPC700.run(20)

    assert still_stopped.stopped?
    assert still_stopped.a == 0
    assert still_stopped.pc == 1
  end

  defp spc_ram(entries) do
    Enum.reduce(entries, :array.new(0x10000, default: 0, fixed: true), fn {address, value}, ram ->
      :array.set(address, value, ram)
    end)
  end
end
