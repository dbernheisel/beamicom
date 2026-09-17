defmodule Beamicom.SNES.PPUObjColorMathTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.SNES.PPU

  test "applies OBJ color math only to palettes 4 through 7" do
    previous_renderer = Application.fetch_env(:beamicom_snes, :ppu_renderer)

    on_exit(fn ->
      case previous_renderer do
        {:ok, renderer} -> Application.put_env(:beamicom_snes, :ppu_renderer, renderer)
        :error -> Application.delete_env(:beamicom_snes, :ppu_renderer)
      end
    end)

    palette_zero = build_obj(0)
    palette_four = build_obj(4)

    Application.put_env(:beamicom_snes, :ppu_renderer, :native)
    native_palette_zero = PPU.render_frame(palette_zero).data
    native_palette_four = PPU.render_frame(palette_four).data

    assert binary_part(native_palette_zero, 0, 3) == <<255, 0, 0>>
    assert binary_part(native_palette_four, 0, 3) == <<255, 255, 0>>

    if Code.ensure_loaded?(Beamicom.SNES.Nx.PPURenderer) do
      Application.put_env(:beamicom_snes, :ppu_renderer, :nx)
      assert PPU.render_frame(palette_zero).data == native_palette_zero
      assert PPU.render_frame(palette_four).data == native_palette_four
    end
  end

  defp build_obj(palette) do
    PPU.new()
    |> PPU.write(0x2100, 0x0F)
    |> PPU.write(0x212C, 0x10)
    |> PPU.write(0x2131, 0x10)
    |> PPU.write(0x2132, 0x5F)
    |> write_vram_byte(0x0000, 0x80)
    |> write_cgram_color(129 + palette * 16, 0x001F)
    |> PPU.write(0x2102, 0)
    |> PPU.write(0x2103, 0)
    |> then(fn ppu ->
      Enum.reduce([0, 0, 0, palette <<< 1], ppu, fn byte, ppu ->
        PPU.write(ppu, 0x2104, byte)
      end)
    end)
  end

  defp write_vram_byte(ppu, byte_address, value) do
    word_address = div(byte_address, 2)
    high? = rem(byte_address, 2) == 1

    ppu
    |> PPU.write(0x2115, if(high?, do: 0x00, else: 0x80))
    |> PPU.write(0x2116, word_address &&& 0xFF)
    |> PPU.write(0x2117, word_address >>> 8)
    |> PPU.write(if(high?, do: 0x2119, else: 0x2118), value)
  end

  defp write_cgram_color(ppu, index, color) do
    ppu
    |> PPU.write(0x2121, index)
    |> PPU.write(0x2122, color &&& 0xFF)
    |> PPU.write(0x2122, color >>> 8)
  end
end
