defmodule Beamicom.Scenic.Video do
  @moduledoc false

  alias Beamicom.GB.PNG
  alias Beamicom.Host.VideoFrame
  alias Beamicom.NES.{Framebuffer, Palette}

  @spec rgb_payload(VideoFrame.t(), keyword()) :: binary()
  def rgb_payload(frame, options \\ [])

  def rgb_payload(%VideoFrame{pixel_format: :rgb24, data: data}, _options)
      when is_binary(data),
      do: data

  def rgb_payload(
        %VideoFrame{pixel_format: {:native, :nes_framebuffer}, data: %Framebuffer{} = frame},
        options
      ) do
    if Keyword.get(options, :grayscale, false),
      do: Palette.to_addr_gray(frame),
      else: Palette.to_rgb(frame)
  end

  def rgb_payload(%VideoFrame{pixel_format: {:native, :dmg_shade_index}, data: data}, _options)
      when is_binary(data),
      do: PNG.to_rgb(data, :dmg_green)

  def rgb_payload(%VideoFrame{pixel_format: format}, _options) do
    raise ArgumentError, "unsupported video pixel format: #{inspect(format)}"
  end

  @spec resize(
          binary(),
          {pos_integer(), pos_integer()},
          {pos_integer(), pos_integer()},
          atom() | nil
        ) :: binary()
  def resize(
        rgb,
        {width, height},
        {output_width, output_height},
        {:pixel_transparency, options}
      )
      when byte_size(rgb) == width * height * 3 and is_list(options),
      do:
        Beamicom.GB.Nx.PixelTransparency.filter(
          rgb,
          {width, height},
          {output_width, output_height},
          options
        )

  def resize(rgb, source_size, output_size, :pixel_transparency),
    do: resize(rgb, source_size, output_size, {:pixel_transparency, []})

  def resize(rgb, {width, height}, {output_width, output_height}, _filter)
      when byte_size(rgb) == width * height * 3 and rem(output_width, width) == 0 and
             rem(output_height, height) == 0 do
    upscale(rgb, width, {div(output_width, width), div(output_height, height)})
  end

  @spec upscale(binary(), pos_integer(), pos_integer() | {pos_integer(), pos_integer()}) ::
          binary()
  def upscale(rgb, width, scale) when is_integer(scale), do: upscale(rgb, width, {scale, scale})
  def upscale(rgb, _width, {1, 1}), do: rgb

  def upscale(rgb, width, {1, scale_y}) when scale_y > 1 do
    row_bytes = width * 3

    for <<row::binary-size(^row_bytes) <- rgb>>,
      into: <<>>,
      do: :binary.copy(row, scale_y)
  end

  def upscale(rgb, width, {scale_x, scale_y}) when scale_x >= 1 and scale_y >= 1 do
    scaled_row_bytes = width * 3 * scale_x

    rows =
      for <<pixel::binary-size(3) <- rgb>>, into: <<>>, do: :binary.copy(pixel, scale_x)

    for <<row::binary-size(^scaled_row_bytes) <- rows>>,
      into: <<>>,
      do: :binary.copy(row, scale_y)
  end
end
