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
    period_ns: [spec: pos_integer(), default: @nes_period_ns],
    pts_offset_ns: [spec: non_neg_integer(), default: 0]
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
       period_ns: opts.period_ns,
       pts_epoch_ns: opts.pts_offset_ns,
       last_number: nil,
       last_pts: nil
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
        {pts, state} = timestamp(frame.number, state.period_ns, state)

        buffer = %Membrane.Buffer{
          payload: Palette.to_rgb(frame),
          pts: pts
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
        {pts, state} = timestamp(frame.number, period_ns, state)

        buffer = %Membrane.Buffer{
          payload: rgb_payload(frame),
          pts: pts
        }

        {[buffer: {:output, buffer}], state}

      nil ->
        {[], state}
    end
  end

  defp reader(NESOutput), do: :nes
  defp reader(_output), do: :host

  defp subscribe(:nes, _output), do: NESOutput.subscribe_video_frames()
  defp subscribe(:host, output), do: Output.subscribe_video(output)

  defp timestamp(number, period_ns, %{last_number: nil} = state) do
    pts = state.pts_epoch_ns + number * period_ns
    {pts, %{state | last_number: number, last_pts: pts}}
  end

  defp timestamp(number, period_ns, %{last_number: last} = state) when number > last do
    pts = state.pts_epoch_ns + number * period_ns
    {pts, %{state | last_number: number, last_pts: pts}}
  end

  defp timestamp(number, period_ns, state) do
    pts = state.last_pts + period_ns
    epoch = pts - number * period_ns
    {pts, %{state | pts_epoch_ns: epoch, last_number: number, last_pts: pts}}
  end
end
