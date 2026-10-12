if Code.ensure_loaded?(Beamicom.GBA.Nx.PPURenderer) do
  defmodule Beamicom.GBA.NxPPURendererTest do
    use ExUnit.Case, async: true

    import Bitwise

    alias Beamicom.GBA.{ScalarPPURenderer, Nx.PPURenderer}
    alias Beamicom.GBA.PPU.ColorCorrection

    test "matches the scalar tiled mode-0 renderer exactly" do
      vram =
        for offset <- 0..(96 * 1024 - 1), into: <<>> do
          <<rem(offset * 37 + div(offset, 97), 256)>>
        end

      palette =
        for index <- 0..511, into: <<>> do
          <<rem(index * 7919, 0x8000)::little-16>>
        end

      oam =
        for index <- 0..127, into: <<>> do
          if index < 4 do
            attr0 = rem(index * 37, 160) ||| rem(index, 2) <<< 13 ||| rem(index, 3) <<< 14
            attr1 = rem(index * 53, 240) ||| rem(index, 4) <<< 14
            attr2 = rem(index * 97, 1024) ||| rem(index, 4) <<< 10 ||| rem(index, 16) <<< 12
            <<attr0::little-16, attr1::little-16, attr2::little-16, 0::little-16>>
          else
            <<0x0200::little-16, 0::little-16, 0::little-16, 0::little-16>>
          end
        end

      registers = %{
        dispcnt: 0x1F40,
        bgcnt: {0x1402, 0x4781, 0x9A00, 0xDF83},
        bghofs: {3, 257, 19, 511},
        bgvofs: {7, 129, 301, 509},
        display_effects: {0, 0, 0, 0, 0, 0, 0, 0, 0x00FF, 0, 7}
      }

      assert PPURenderer.render_mode0(vram, palette, oam, registers) ==
               ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    end

    test "matches scalar Mode 0 when BG2 is disabled on every captured scanline" do
      vram =
        for(offset <- 0..(96 * 1024 - 1), into: <<>>, do: <<rem(offset * 37, 256)>>)

      palette =
        for index <- 0..511, into: <<>> do
          <<rem(index * 7_919, 0x8000)::little-16>>
        end

      dispcnt = 0x1B00

      registers =
        registers(
          dispcnt: dispcnt,
          bgcnt: {0x1402, 0x4781, 0x9A00, 0xDF83},
          bghofs: {3, 257, 19, 511},
          bgvofs: {7, 129, 301, 509},
          scanline_dispcnt: List.duplicate(dispcnt, 160) |> List.to_tuple()
        )

      assert PPURenderer.render_mode0(vram, palette, hidden_oam(), registers) ==
               ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
    end

    test "matches the scalar mode-3 renderer with regular objects" do
      vram =
        for(offset <- 0..(96 * 1024 - 1), into: <<>>, do: <<rem(offset * 29, 256)>>)
        |> replace(0x14_000, :binary.copy(<<0x21>>, 32))

      palette =
        for index <- 0..511, into: <<>> do
          <<rem(index * 7919, 0x8000)::little-16>>
        end

      first_object = <<0x0000::little-16, 0x0000::little-16, 0x0200::little-16, 0::16>>
      oam = replace(hidden_oam(), 0, first_object)

      registers = %{
        dispcnt: 0x1403,
        bgcnt: {0, 0, 2, 0},
        bghofs: {0, 0, 0, 0},
        bgvofs: {0, 0, 0, 0}
      }

      assert PPURenderer.render_mode3(vram, palette, oam, registers) ==
               ScalarPPURenderer.render_mode3(vram, palette, oam, registers)
    end

    test "matches the scalar renderer with affine objects" do
      vram =
        for(offset <- 0..(96 * 1024 - 1), into: <<>>, do: <<rem(offset * 29, 256)>>)
        |> replace(0x10_000, :binary.copy(<<0x21>>, 32))

      palette =
        for index <- 0..511, into: <<>> do
          <<rem(index * 7_919, 0x8000)::little-16>>
        end

      oam =
        hidden_oam()
        |> replace(0, <<0x0700::little-16, 0x4000::little-16, 0x0000::little-16>>)
        |> replace(6, <<0x00B5::little-16>>)
        |> replace(14, <<0xFF4B::little-16>>)
        |> replace(22, <<0x00B5::little-16>>)
        |> replace(30, <<0x00B5::little-16>>)

      registers = %{
        dispcnt: 0x1000,
        bgcnt: {0, 0, 0, 0},
        bghofs: {0, 0, 0, 0},
        bgvofs: {0, 0, 0, 0},
        display_effects: {0, 0, 0, 0, 0, 0, 0, 0, 0x2000, 0x0808, 0}
      }

      assert PPURenderer.render_mode0(vram, palette, oam, registers) ==
               ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
    end

    test "matches wrapped double-size affine objects" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x10_000, :binary.copy(<<0x11>>, 2_048))

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace((256 + 1) * 2, <<0x03E0::little-16>>)

      oam =
        hidden_oam()
        |> replace(0, <<0x039F::little-16, 0xC000::little-16, 0x0000::little-16>>)
        |> replace(6, <<0x0080::little-16>>)
        |> replace(14, <<0x0000::little-16>>)
        |> replace(22, <<0x0000::little-16>>)
        |> replace(30, <<0x0080::little-16>>)

      registers = registers(dispcnt: 0x1040)
      scalar = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
      accelerated = PPURenderer.render_mode0(vram, palette, oam, registers)

      assert binary_part(scalar, 0, 3) == ColorCorrection.rgb24(0x03E0)
      assert binary_part(scalar, 159 * 240 * 3, 3) == <<0, 0, 0>>
      assert accelerated == scalar
    end

    test "selects the highest-priority opaque object before OAM index" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x10_000, :binary.copy(<<0x11>>, 32))
        |> replace(0x10_020, :binary.copy(<<0x22>>, 32))

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace((256 + 1) * 2, <<0x001F::little-16>>)
        |> replace((256 + 2) * 2, <<0x03E0::little-16>>)

      oam =
        hidden_oam()
        |> replace(0, <<0::little-16, 0::little-16, 0x0C00::little-16, 0::little-16>>)
        |> replace(8, <<0::little-16, 0::little-16, 0x0001::little-16, 0::little-16>>)

      registers = registers(dispcnt: 0x1000)
      scalar = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
      accelerated = PPURenderer.render_mode0(vram, palette, oam, registers)

      assert binary_part(scalar, 0, 3) == ColorCorrection.rgb24(0x03E0)
      assert accelerated == scalar
    end

    test "blends a foreground background with the object layer immediately behind it" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x20, :binary.copy(<<0x11>>, 32))
        |> replace(0x800, <<1::little-16>>)
        |> replace(0x10_000, :binary.copy(<<0x22>>, 32))

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace(2, <<0x001F::little-16>>)
        |> replace((256 + 2) * 2, <<0x7C00::little-16>>)

      object = <<0::little-16, 0::little-16, 0x0400::little-16, 0::little-16>>
      oam = replace(hidden_oam(), 0, object)

      registers =
        registers(
          dispcnt: 0x1100,
          bgcnt: {0x0100, 0, 0, 0},
          display_effects: {0, 0, 0, 0, 0, 0, 0, 0, 0x1041, 0x0808, 0}
        )

      scalar = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
      accelerated = PPURenderer.render_mode0(vram, palette, oam, registers)

      assert binary_part(scalar, 0, 3) == ColorCorrection.rgb24(0x3C0F)
      assert accelerated == scalar
    end

    test "matches regular-window layer masks and color-effect gating" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x20, :binary.copy(<<0x11>>, 32))
        |> replace(0x40, :binary.copy(<<0x22>>, 32))
        |> replace(0x800, :binary.copy(<<1::little-16>>, 33))
        |> replace(0x1000, :binary.copy(<<2::little-16>>, 33))

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace(2, <<0x001F::little-16>>)
        |> replace(4, <<0x03E0::little-16>>)

      registers =
        registers(
          dispcnt: 0x2300,
          bgcnt: {0x0100, 0x0201, 0, 0},
          display_effects: {
            0x0008,
            0,
            0x0008,
            0,
            0x0002,
            0x0021,
            0,
            0,
            0x00C1,
            0,
            8
          }
        )

      scalar = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
      accelerated = PPURenderer.render_mode0(vram, palette, hidden_oam(), registers)

      assert binary_part(scalar, 0, 3) == ColorCorrection.rgb24(0x03E0)
      assert binary_part(scalar, 8 * 3, 3) == ColorCorrection.rgb24(0x0010)
      assert accelerated == scalar
    end

    test "matches OBJ-window masks" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x20, :binary.copy(<<0x11>>, 32))
        |> replace(0x800, :binary.copy(<<1::little-16>>, 2))
        |> replace(0x10_000, :binary.copy(<<0x11>>, 32))

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace(2, <<0x001F::little-16>>)

      object_window = <<0x0800::little-16, 0::little-16, 0::little-16, 0::little-16>>
      oam = replace(hidden_oam(), 0, object_window)

      registers =
        registers(
          dispcnt: 0x9100,
          bgcnt: {0x0100, 0, 0, 0},
          display_effects: {0, 0, 0, 0, 0, 0x0001, 0, 0, 0, 0, 0}
        )

      scalar = ScalarPPURenderer.render_mode0(vram, palette, oam, registers)
      accelerated = PPURenderer.render_mode0(vram, palette, oam, registers)

      assert binary_part(scalar, 0, 3) == <<0, 0, 0>>
      assert binary_part(scalar, 8 * 3, 3) == ColorCorrection.rgb24(0x001F)
      assert accelerated == scalar
    end

    test "matches the scalar Mode 1 affine background renderer" do
      vram =
        for offset <- 0..(96 * 1024 - 1), into: <<>> do
          <<rem(offset * 31 + div(offset, 89), 256)>>
        end

      palette =
        for index <- 0..511, into: <<>> do
          <<rem(index * 7_919, 0x8000)::little-16>>
        end

      registers = %{
        dispcnt: 0x1741,
        bgcnt: {0x0201, 0x0702, 0x6383, 0},
        bghofs: {13, 257, 0, 0},
        bgvofs: {29, 133, 0, 0},
        scanline_bgcnt:
          for(y <- 0..159, do: {0x0201 ||| rem(y, 2) <<< 7, 0x0702, 0x6383, 0})
          |> List.to_tuple(),
        bg_affine:
          {{0x00E0, 0xFFE0, 0x0020, 0x00E0, 0x0FFF_E000, 0x0000_1800},
           {0x0100, 0, 0, 0x0100, 0, 0}}
      }

      oam = hidden_oam()

      assert PPURenderer.render_mode1(vram, palette, oam, registers) ==
               ScalarPPURenderer.render_mode1(vram, palette, oam, registers)
    end

    test "matches scalar rendering across a per-scanline tiled mode switch" do
      vram =
        :binary.copy(<<0>>, 96 * 1024)
        |> replace(0x20, :binary.copy(<<0x11>>, 32))
        |> replace(0x800, <<1::little-16>>)
        |> replace(0x4000 + 2 * 64, :binary.copy(<<2>>, 64))
        |> replace(0x1000, <<2>>)

      palette =
        :binary.copy(<<0>>, 1024)
        |> replace(2, <<0x001F::little-16>>)
        |> replace(4, <<0x03E0::little-16>>)

      for split <- [74, 75] do
        registers =
          registers(
            dispcnt: 0x0400,
            bgcnt: {0, 0, 0x0100, 0},
            scanline_dispcnt:
              (List.duplicate(0x0400, split) ++ List.duplicate(0x0401, 160 - split))
              |> List.to_tuple(),
            scanline_bgcnt:
              (List.duplicate({0, 0, 0x0100, 0}, split) ++
                 List.duplicate({0, 0, 0x0204, 0}, 160 - split))
              |> List.to_tuple()
          )

        scalar = ScalarPPURenderer.render_mode0(vram, palette, hidden_oam(), registers)
        accelerated = PPURenderer.render_mode0(vram, palette, hidden_oam(), registers)

        assert binary_part(scalar, 0, 3) == ColorCorrection.rgb24(0x001F)
        assert accelerated == scalar
      end
    end

    defp hidden_oam do
      :binary.copy(<<0x0200::little-16, 0::little-16, 0::little-16, 0::little-16>>, 128)
    end

    defp registers(overrides) do
      Map.merge(
        %{
          dispcnt: 0,
          bgcnt: {0, 0, 0, 0},
          bghofs: {0, 0, 0, 0},
          bgvofs: {0, 0, 0, 0}
        },
        Map.new(overrides)
      )
    end

    defp replace(binary, offset, replacement) do
      size = byte_size(replacement)
      <<prefix::binary-size(^offset), _old::binary-size(^size), suffix::binary>> = binary
      prefix <> replacement <> suffix
    end
  end
end
