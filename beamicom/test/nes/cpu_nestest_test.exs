defmodule Beamicom.NES.CPUNestestTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Cart, Bus, CPU}

  @moduledoc """
  Golden-master trace: run nestest.nes in automated mode ($C000 entry) and diff
  the CPU register columns against the published cycle-accurate log. Per spec §5.1
  we compare PC/A/X/Y/P/SP/CYC only (no disassembly, no PPU columns).
  """

  @line ~r/^(?<pc>[0-9A-F]{4}).*A:(?<a>[0-9A-F]{2}) X:(?<x>[0-9A-F]{2}) Y:(?<y>[0-9A-F]{2}) P:(?<p>[0-9A-F]{2}) SP:(?<sp>[0-9A-F]{2}).*CYC:(?<cyc>\d+)/

  defp parse(line) do
    %{"pc" => pc, "a" => a, "x" => x, "y" => y, "p" => p, "sp" => sp, "cyc" => cyc} =
      Regex.named_captures(@line, line)

    %{
      pc: String.to_integer(pc, 16),
      a: String.to_integer(a, 16),
      x: String.to_integer(x, 16),
      y: String.to_integer(y, 16),
      p: String.to_integer(p, 16),
      sp: String.to_integer(sp, 16),
      cycles: String.to_integer(cyc)
    }
  end

  defp actual(cpu) do
    %{pc: cpu.pc, a: cpu.a, x: cpu.x, y: cpu.y, p: cpu.p, sp: cpu.sp, cycles: cpu.cycles}
  end

  test "matches nestest.log register trace" do
    {:ok, cart} = Cart.parse(File.read!("test/support/fixtures/nestest.nes"))
    bus = Bus.new(cart)
    # Automated mode: enter at $C000 with the pinned nestest power-on state.
    cpu = %CPU{pc: 0xC000, sp: 0xFD, p: 0x24, a: 0, x: 0, y: 0, cycles: 7}

    lines = "test/support/fixtures/nestest.log" |> File.read!() |> String.split("\n", trim: true)

    Enum.reduce(Enum.with_index(lines, 1), {cpu, bus}, fn {line, n}, {cpu, bus} ->
      exp = parse(line)
      got = actual(cpu)

      if got != exp do
        flunk("""
        Divergence at log line #{n}:
          expected #{inspect(exp, base: :hex)}
          got      #{inspect(got, base: :hex)}
        """)
      end

      CPU.step(cpu, bus)
    end)
  end
end
