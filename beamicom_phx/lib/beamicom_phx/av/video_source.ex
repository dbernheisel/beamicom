defmodule BeamicomPhx.AV.VideoSource do
  @moduledoc """
  Membrane push source: subscribes to `Beamicom.NES.Output` video notifications,
  reads the latest frame from ETS, resolves it to RGB with `Beamicom.NES.Palette`,
  and emits it as a `Membrane.RawVideo` buffer. The emulator is the clock, so this
  is a `:push` source driven entirely by `{:frame, number}` messages.
  """
  use Membrane.Source

  alias Beamicom.NES.{Framebuffer, Output, Palette}

  @width 256
  @height 240
  # NTSC ~60.0988 fps; PTS derived from the frame number so it never drifts.
  @period_ns round(1_000_000_000 / 60.0988)

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{}}

  @impl true
  def handle_playing(_ctx, state) do
    Output.subscribe_video()

    format = %Membrane.RawVideo{
      width: @width,
      height: @height,
      pixel_format: :RGB,
      framerate: nil,
      aligned: true
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_info({:frame, number}, _ctx, state) do
    case Output.latest() do
      %Framebuffer{} = frame ->
        buffer = %Membrane.Buffer{
          payload: Palette.to_rgb(frame),
          pts: number * @period_ns
        }

        {[buffer: {:output, buffer}], state}

      nil ->
        {[], state}
    end
  end
end
