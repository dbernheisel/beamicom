defmodule BeamicomPhx.AV.AudioSource do
  @moduledoc """
  Membrane push source: subscribes to `Beamicom.NES.Output` audio and emits each
  pre-encoded signed-16-bit little-endian PCM chunk as a `Membrane.RawAudio`
  buffer (44100 Hz mono — the APU's native rate).

  Unlike video (latest-frame coalesced), audio is a stream — every chunk is
  forwarded so no samples are dropped. PTS accumulates by cumulative sample
  count so it is monotonic and drift-free.
  """
  use Membrane.Source

  alias Beamicom.NES.Output

  @sample_rate 44_100

  def_output_pad(:output,
    accepted_format: %Membrane.RawAudio{
      channels: 1,
      sample_rate: @sample_rate,
      sample_format: :s16le
    },
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{count: 0}}

  @impl true
  def handle_playing(_ctx, state) do
    Output.subscribe_audio()

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
