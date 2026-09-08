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

  @spec upscale(binary(), pos_integer(), pos_integer()) :: binary()
  def upscale(rgb, _width, 1), do: rgb

  def upscale(rgb, width, scale) when scale > 1 do
    scaled_row_bytes = width * 3 * scale
    rows = for <<pixel::binary-size(3) <- rgb>>, into: <<>>, do: :binary.copy(pixel, scale)

    for <<row::binary-size(^scaled_row_bytes) <- rows>>,
      into: <<>>,
      do: :binary.copy(row, scale)
  end
end
