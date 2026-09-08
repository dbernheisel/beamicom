defmodule BeamicomStream.AV.VideoSource do
  @moduledoc "Membrane push source for the latest system-neutral Beamicom video frame."
  use Membrane.Source

  alias Beamicom.GB.PNG
  alias Beamicom.Host.{Output, VideoFrame}
  alias Beamicom.NES.{Framebuffer, Palette}
  alias Beamicom.NES.Output, as: NESOutput

  @nes_period_ns round(1_000_000_000 / 60.0988)

  def_options(
    owner: [spec: pid() | nil, default: nil],
    output: [spec: term(), default: Beamicom.NES.Output],
    width: [spec: pos_integer(), default: 256],
    height: [spec: pos_integer(), default: 240],
    period_ns: [spec: pos_integer(), default: @nes_period_ns]
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       owner: opts.owner,
       output: opts.output,
       reader: reader(opts.output),
       width: opts.width,
       height: opts.height,
       period_ns: opts.period_ns
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    subscribe(state.reader, state.output)
    if state.owner, do: send(state.owner, {:beamicom_stream_source_ready, :video})

    format = %Membrane.RawVideo{
      width: state.width,
      height: state.height,
      pixel_format: :RGB,
      framerate: nil,
      aligned: true
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_info({:video_frame, _system, _number}, _ctx, state), do: push_latest(state)
  def handle_info({:frame, _number}, _ctx, state), do: push_latest(state)

  @doc false
  @spec rgb_payload(VideoFrame.t()) :: binary()
  def rgb_payload(%VideoFrame{pixel_format: :rgb24, data: data}) when is_binary(data), do: data

  def rgb_payload(%VideoFrame{
        pixel_format: {:native, :nes_framebuffer},
        data: %Framebuffer{} = frame
      }),
      do: Palette.to_rgb(frame)

  def rgb_payload(%VideoFrame{pixel_format: {:native, :dmg_shade_index}, data: data}),
    do: PNG.to_rgb(data, :dmg_green)

  defp push_latest(%{reader: :nes} = state) do
    case NESOutput.latest() do
      %Framebuffer{} = frame ->
        buffer = %Membrane.Buffer{
          payload: Palette.to_rgb(frame),
          pts: frame.number * state.period_ns
        }

        {[buffer: {:output, buffer}], state}

      nil ->
        {[], state}
    end
  end

  defp push_latest(%{reader: :host} = state) do
    case Output.latest_video(state.output) do
      %VideoFrame{} = frame ->
        period_ns = frame.duration_ns || state.period_ns
        buffer = %Membrane.Buffer{payload: rgb_payload(frame), pts: frame.number * period_ns}
        {[buffer: {:output, buffer}], state}

      nil ->
        {[], state}
    end
  end

  defp reader(NESOutput), do: :nes
  defp reader(_output), do: :host

  defp subscribe(:nes, _output), do: NESOutput.subscribe_video_frames()
  defp subscribe(:host, output), do: Output.subscribe_video(output)
end
