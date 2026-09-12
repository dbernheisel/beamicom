defmodule NxNes.ElixirLoop do
  @moduledoc "Equivalent block specialization on BEAM, to control for removing CPU dispatch."
  import Bitwise

  def run(cpu, bus, iterations) do
    dst = Beamicom.NES.Bus.peek(bus, cpu.pc + 1)
    src = Beamicom.NES.Bus.peek(bus, cpu.pc + 6)
    {a, p, ram} = loop(cpu.a, cpu.p, bus.ram, dst, src, iterations)
    {%{cpu | a: a, p: p, cycles: cpu.cycles + iterations * 19}, %{bus | ram: ram}}
  end

  defp loop(a, p, ram, _dst, _src, 0), do: {a, p, ram}

  defp loop(_a, p, ram, dst, src, n) do
    inc = :binary.at(ram, dst) + 1 &&& 255
    operand = if src == dst, do: inc, else: :binary.at(ram, src)
    sum = inc + operand
    result = sum &&& 255
    overflow = (bxor(inc, result) &&& bxor(operand, result) &&& 128) != 0
    p = (p &&& 60) ||| (result &&& 128) ||| if(result == 0, do: 2, else: 0)
    p = p ||| if(sum > 255, do: 1, else: 0) ||| if(overflow, do: 64, else: 0)
    <<prefix::binary-size(^dst), _, suffix::binary>> = ram
    ram = <<prefix::binary, result, suffix::binary>>
    loop(result, p, ram, dst, src, n - 1)
  end
end
