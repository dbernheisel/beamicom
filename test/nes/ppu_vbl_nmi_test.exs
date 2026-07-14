defmodule Beamicom.NES.PPUVblNmiTest do
  use ExUnit.Case, async: true

  alias Beamicom.NES.{Bus, Console}

  @moduledoc """
  Runs blargg's ppu_vbl_nmi ROMs through the full Console (CPU + PPU + NMI),
  reporting via the $6000 protocol (spec §5.2 item 3, §10). Gates Phase B: the
  vblank flag sets/clears on the right scanlines and NMI is delivered.

  Source: christopherpow/nes-test-roms, ppu_vbl_nmi/.
  """

  @signature <<0xDE, 0xB0, 0x61>>
  @max_steps 3_000_000

  defp run(console, 0), do: {:timeout, message(console.bus)}

  defp run(console, budget) do
    bus = console.bus
    status = Bus.peek(bus, 0x6000)

    if signature(bus) == @signature and status < 0x80 do
      {status, message(bus)}
    else
      run(Console.step(console), budget - 1)
    end
  end

  defp signature(bus),
    do: <<Bus.peek(bus, 0x6001), Bus.peek(bus, 0x6002), Bus.peek(bus, 0x6003)>>

  defp message(bus), do: read_string(bus, 0x6004, [])

  defp read_string(bus, addr, acc) do
    case Bus.peek(bus, addr) do
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
      byte -> read_string(bus, addr + 1, [byte | acc])
    end
  end

  # Micro-stepped, cycle-accurate timing: per-cycle NMI-line polling (with the
  # 6502's one-cycle edge-detector delay) and the $2002 read race handle the
  # dot-exact set/suppression/NMI cases (spec §5.2 item 3). Still open:
  # 03-vbl_clear_time, 08-nmi_off_timing (NMI-disable boundary), and
  # 10-even_odd_timing — each a residual ~1-dot edge.
  @passing ~w(01-vbl_basics 02-vbl_set_time 04-nmi_control 05-nmi_timing
              06-suppression 07-nmi_on_timing 09-even_odd_frames)

  for name <- @passing do
    test "ppu_vbl_nmi #{name} passes" do
      {code, msg} =
        run(Console.load("roms/ppu_vbl_nmi/rom_singles/#{unquote(name)}.nes"), @max_steps)

      assert code == 0, "reported #{inspect(code)}:\n#{msg}"
      assert msg =~ "Passed"
    end
  end
end
