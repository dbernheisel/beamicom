defmodule Beamicom.NES.BlarggTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Cart, Bus, CPU}

  @moduledoc """
  Runs blargg's CPU test ROMs headlessly (spec §10). These report results
  through cartridge WRAM: $6000 holds the status byte ($80 = running, then a
  result code where 0 = passed), $6001-$6003 hold the signature $DE $B0 $61
  once the framework is live, and a null-terminated ASCII message starts at
  $6004.

  Source: blargg's nes-test-roms, instr_test-v5/ (christopherpow/nes-test-roms).
  """

  @signature <<0xDE, 0xB0, 0x61>>
  @max_steps 30_000_000

  # Step until the framework reports a terminal status, then read code + message.
  defp run(bus) do
    drive(CPU.reset(bus), bus, @max_steps)
  end

  defp drive(_cpu, bus, 0), do: {:timeout, message(bus)}

  defp drive(cpu, bus, budget) do
    status = Bus.peek(bus, 0x6000)

    cond do
      signature(bus) == @signature and status < 0x80 -> {status, message(bus)}
      true -> (fn {c, b} -> drive(c, b, budget - 1) end).(CPU.step(cpu, bus))
    end
  end

  defp signature(bus), do: <<Bus.peek(bus, 0x6001), Bus.peek(bus, 0x6002), Bus.peek(bus, 0x6003)>>

  defp message(bus), do: read_string(bus, 0x6004, [])

  defp read_string(bus, addr, acc) do
    case Bus.peek(bus, addr) do
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
      byte -> read_string(bus, addr + 1, [byte | acc])
    end
  end

  @singles ~w(01-basics 02-implied 03-immediate 04-zero_page 05-zp_xy 06-absolute
              07-abs_xy 08-ind_x 09-ind_y 10-branches 11-stack 12-jmp_jsr 13-rts
              14-rti 15-brk 16-special)

  defp assert_passes(name) do
    {:ok, cart} =
      Cart.parse(File.read!("test/support/fixtures/instr_test-v5/rom_singles/#{name}.nes"))

    {code, msg} = run(Bus.new(cart))
    assert code == 0, "blargg reported code #{inspect(code)}:\n#{msg}"
    assert msg =~ "Passed"
  end

  for name <- @singles do
    test "instr_test-v5 #{name} passes", do: assert_passes(unquote(name))
  end
end
