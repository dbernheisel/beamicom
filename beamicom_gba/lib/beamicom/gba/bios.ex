defmodule Beamicom.GBA.BIOS do
  @moduledoc false

  @size 16 * 1024

  @doc "Returns a clean-room IRQ trampoline for deterministic skip-boot execution."
  def hle do
    code =
      <<
        0::little-size(0x18 * 8),
        0xE92D_500F::little-32,
        0xE59F_0010::little-32,
        0xE590_0000::little-32,
        0xE1A0_E00F::little-32,
        0xE12F_FF10::little-32,
        0xE8BD_500F::little-32,
        0xE25E_F004::little-32,
        0x0300_7FFC::little-32
      >>

    code <> :binary.copy(<<0>>, @size - byte_size(code))
  end
end
