defmodule BeamicomV4L2.Video do
  @moduledoc false

  alias Beamicom.GB.PNG
  alias Beamicom.Host.VideoFrame
  alias Beamicom.NES.{Framebuffer, Palette}

  @spec rgb_payload(VideoFrame.t()) :: binary()
  def rgb_payload(%VideoFrame{pixel_format: :rgb24, data: data}) when is_binary(data), do: data

  def rgb_payload(%VideoFrame{
        pixel_format: {:native, :nes_framebuffer},
        data: %Framebuffer{} = framebuffer
      }),
      do: Palette.to_rgb(framebuffer)

  def rgb_payload(%VideoFrame{pixel_format: {:native, :dmg_shade_index}, data: data})
      when is_binary(data),
      do: PNG.to_rgb(data, :dmg_green)

  def rgb_payload(%VideoFrame{pixel_format: format}) do
    raise ArgumentError, "unsupported video pixel format: #{inspect(format)}"
  end
end
