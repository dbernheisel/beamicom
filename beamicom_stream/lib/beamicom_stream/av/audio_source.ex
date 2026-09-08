defmodule BeamicomStream.AV.AudioSource do
  @moduledoc """
  Membrane push source for Beamicom's system-neutral PCM audio chunks.

  Envelopes that do not match the negotiated channel count, sample rate, and
  sample format are ignored rather than being sent into a misconfigured codec.
  """
  use Membrane.Source

  alias Beamicom.Host.{AudioChunk, Output}
  @sample_rate 44_100

  def_options(
    owner: [spec: pid() | nil, default: nil],
    output: [spec: term(), default: Beamicom.NES.Output],
    channels: [spec: 1 | 2, default: 1],
    sample_rate: [spec: pos_integer(), default: @sample_rate],
    sample_format: [spec: atom(), default: :s16le],
    pts_offset_ns: [spec: non_neg_integer(), default: 0]
  )

  def_output_pad(:output,
    accepted_format:
      %Membrane.RawAudio{channels: channels, sample_rate: @sample_rate, sample_format: :s16le}
      when channels in [1, 2],
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       count: 0,
       owner: opts.owner,
       output: opts.output,
       channels: opts.channels,
       sample_rate: opts.sample_rate,
       sample_format: opts.sample_format,
       pts_offset_ns: opts.pts_offset_ns
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    Output.subscribe_audio(state.output)
    if state.owner, do: send(state.owner, {:beamicom_stream_source_ready, :audio})

    format = %Membrane.RawAudio{
      channels: state.channels,
      sample_rate: state.sample_rate,
      sample_format: state.sample_format
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_info(
        {:audio_chunk,
         %AudioChunk{channels: channels, sample_rate: sample_rate, sample_format: sample_format} =
           chunk},
        _ctx,
        %{channels: channels, sample_rate: sample_rate, sample_format: sample_format} = state
      ) do
    buffer = %Membrane.Buffer{
      payload: chunk.data,
      pts: state.pts_offset_ns + div(state.count * 1_000_000_000, state.sample_rate)
    }

    {[buffer: {:output, buffer}], %{state | count: state.count + chunk.frame_count}}
  end

  def handle_info({:audio_chunk, %AudioChunk{}}, _ctx, state), do: {[], state}

  def handle_info({:audio, sample_count, pcm}, ctx, state) do
    chunk = %AudioChunk{
      system: :nes,
      sample_rate: state.sample_rate,
      channels: state.channels,
      sample_format: state.sample_format,
      frame_count: sample_count,
      data: pcm
    }

    handle_info({:audio_chunk, chunk}, ctx, state)
  end
end
