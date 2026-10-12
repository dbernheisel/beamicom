defmodule Beamicom.GBA.CPU.ALUTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.CPU.ALU

  test "reports ARM carry and signed overflow independently" do
    assert {0, true, false} = ALU.add(0xFFFF_FFFF, 1)
    assert {0x8000_0000, false, true} = ALU.add(0x7FFF_FFFF, 1)
    assert {0xFFFF_FFFF, false, false} = ALU.subtract(0, 1)
    assert {0x7FFF_FFFF, true, true} = ALU.subtract(0x8000_0000, 1)
  end

  test "implements immediate shift edge cases" do
    assert {0, true} = ALU.shift_immediate(0x8000_0000, 1, 0, false)
    assert {0xFFFF_FFFF, true} = ALU.shift_immediate(0x8000_0000, 2, 0, false)
    assert {0x8000_0001, true} = ALU.shift_immediate(3, 3, 0, true)
  end

  test "evaluates ARM condition codes from CPSR flags" do
    cpsr = 0xA000_001F
    assert ALU.condition_passed?(0x2, cpsr)
    assert ALU.condition_passed?(0x4, cpsr)
    refute ALU.condition_passed?(0x0, cpsr)
    refute ALU.condition_passed?(0xA, cpsr)
    assert ALU.condition_passed?(0xB, cpsr)
    refute ALU.condition_passed?(0xC, cpsr)
  end
end
