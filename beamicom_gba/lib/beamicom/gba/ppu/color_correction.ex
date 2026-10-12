defmodule Beamicom.GBA.PPU.ColorCorrection do
  @moduledoc """
  Fixed Game Boy Advance LCD color response applied at final PPU conversion.

  The transform follows libretro's
  [`vba-color.glsl`](https://github.com/libretro/glsl-shaders/blob/master/handheld/shaders/color/vba-color.glsl)
  matrix order with the emulator's configured gamma, saturation, luminance,
  and channel-crosstalk values. Identity and zero-value parameters are folded
  out. Since every composed GBA pixel is BGR555, the fixed transform is
  compiled into a lookup table shared by the scalar and Nx renderers.
  """

  import Bitwise

  @input_gamma 1.45 + 0.4 * 1.7
  @display_gamma 1.45
  @saturation 1.2
  @luminance 1.1

  @red_scale 0.73
  @green_scale 0.8
  @blue_scale 0.73
  @red_to_green 0.085
  @red_to_blue 0.085
  @green_to_red 0.27
  @green_to_blue 0.24
  @blue_to_red 0.0
  @blue_to_green 0.24

  @rgb24_table (
                 clamp = fn value -> max(0.0, min(1.0, value)) end

                 expand = fn value -> value <<< 3 ||| value >>> 2 end

                 correct = fn pixel ->
                   red = pixel &&& 0x1F
                   green = pixel >>> 5 &&& 0x1F
                   blue = pixel >>> 10 &&& 0x1F

                   red = :math.pow(expand.(red) / 255.0, @input_gamma)
                   green = :math.pow(expand.(green) / 255.0, @input_gamma)
                   blue = :math.pow(expand.(blue) / 255.0, @input_gamma)

                   red = clamp.(red * @luminance)
                   green = clamp.(green * @luminance)
                   blue = clamp.(blue * @luminance)
                   average = red * 0.3086 + green * 0.6094 + blue * 0.0820
                   inverse_saturation = 1.0 - @saturation

                   saturated_red = @saturation * red + inverse_saturation * average
                   saturated_green = @saturation * green + inverse_saturation * average
                   saturated_blue = @saturation * blue + inverse_saturation * average

                   corrected_red =
                     @red_scale * saturated_red + @green_to_red * saturated_green +
                       @blue_to_red * saturated_blue

                   corrected_green =
                     @red_to_green * saturated_red + @green_scale * saturated_green +
                       @blue_to_green * saturated_blue

                   corrected_blue =
                     @red_to_blue * saturated_red + @green_to_blue * saturated_green +
                       @blue_scale * saturated_blue

                   to_byte = fn value ->
                     value
                     |> clamp.()
                     |> :math.pow(1.0 / @display_gamma)
                     |> Kernel.*(255.0)
                     |> round()
                   end

                   <<to_byte.(corrected_red), to_byte.(corrected_green),
                     to_byte.(corrected_blue)>>
                 end

                 for pixel <- 0..0x7FFF, into: <<>>, do: correct.(pixel)
               )

  @doc "Converts a composed BGR555 color to corrected RGB24."
  def rgb24(pixel) when is_integer(pixel) and pixel >= 0 do
    binary_part(@rgb24_table, (pixel &&& 0x7FFF) * 3, 3)
  end

  @doc false
  def rgb24_table, do: @rgb24_table
end
