defmodule BeamicomStream.AV.VideoSource do
  @moduledoc "Membrane push source for Beamicom's latest RGB video frame."
  use Membrane.Source

  alias Beamicom.NES.{Framebuffer, Output, Palette}

  @width 256
  @height 240
  @period_ns round(1_000_000_000 / 60.0988)

  def_options(owner: [spec: pid() | nil, default: nil])

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{owner: opts.owner}}

  @impl true
  def handle_playing(_ctx, state) do
    Output.subscribe_video()
    if state.owner, do: send(state.owner, {:beamicom_stream_source_ready, :video})

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
        buffer = %Membrane.Buffer{payload: Palette.to_rgb(frame), pts: number * @period_ns}
        {[buffer: {:output, buffer}], state}

      nil ->
        {[], state}
    end
  end
end
