defmodule BeamicomStream.AV.AudioSource do
  @moduledoc "Membrane push source for Beamicom's 44.1 kHz mono s16le audio."
  use Membrane.Source

  alias Beamicom.NES.Output
  @sample_rate 44_100

  def_options(owner: [spec: pid() | nil, default: nil])

  def_output_pad(:output,
    accepted_format: %Membrane.RawAudio{
      channels: 1,
      sample_rate: @sample_rate,
      sample_format: :s16le
    },
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{count: 0, owner: opts.owner}}

  @impl true
  def handle_playing(_ctx, state) do
    Output.subscribe_audio()
    if state.owner, do: send(state.owner, {:beamicom_stream_source_ready, :audio})

    format = %Membrane.RawAudio{
      channels: 1,
      sample_rate: @sample_rate,
      sample_format: :s16le
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_info({:audio, sample_count, pcm}, _ctx, state) do
    buffer = %Membrane.Buffer{
      payload: pcm,
      pts: div(state.count * 1_000_000_000, @sample_rate)
    }

    {[buffer: {:output, buffer}], %{state | count: state.count + sample_count}}
  end
end
