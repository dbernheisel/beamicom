defmodule Beamicom.NES.Output do
  @moduledoc """
  NES compatibility facade over the system-neutral `Beamicom.Host.Output` hub.

  Existing sinks retain the `{:frame, number}` and
  `{:audio, sample_count, pcm}` protocol. New hosts can subscribe to typed
  `Beamicom.Host.VideoFrame` and `Beamicom.Host.AudioChunk` envelopes through
  `subscribe_video_frames/0` and `subscribe_audio_chunks/0`.
  """

  alias Beamicom.Host.{AudioChunk, VideoFrame}
  alias Beamicom.Host.Output, as: HostOutput
  alias Beamicom.NES.Framebuffer

  @period_ns round(1_000_000_000 / 60.0988)
  @sample_rate 44_100

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {HostOutput, :start_link, [[name: __MODULE__, table: :nes_frames]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(_opts \\ []), do: HostOutput.start_link(name: __MODULE__, table: :nes_frames)

  @doc "Publish an NES framebuffer without blocking the emulator loop."
  def publish(%Framebuffer{} = frame), do: frame |> video_frame() |> publish_video()

  @doc "Publish an already wrapped NES video frame."
  def publish_video(%VideoFrame{system: :nes} = frame),
    do: HostOutput.publish_video(__MODULE__, frame)

  @doc "Publish signed-16-bit little-endian mono PCM."
  def publish_audio(0, <<>>), do: :ok

  def publish_audio(sample_count, pcm) when is_integer(sample_count) and is_binary(pcm) do
    publish_audio(sample_count, pcm, @sample_rate)
  end

  @doc "Publish signed-16-bit little-endian mono PCM at an explicit sample rate."
  def publish_audio(0, <<>>, _sample_rate), do: :ok

  def publish_audio(sample_count, pcm, sample_rate)
      when is_integer(sample_count) and is_binary(pcm) and is_integer(sample_rate) do
    publish_audio_chunk(%AudioChunk{
      system: :nes,
      sample_rate: sample_rate,
      channels: 1,
      sample_format: :s16le,
      frame_count: sample_count,
      data: pcm
    })
  end

  @doc "Publish an already wrapped NES audio chunk."
  def publish_audio_chunk(%AudioChunk{system: :nes} = chunk),
    do: HostOutput.publish_audio(__MODULE__, chunk)

  @doc "Subscribe using the original NES video notification protocol."
  def subscribe_video, do: HostOutput.subscribe_video(__MODULE__, :legacy)

  @doc "Subscribe using the original NES audio notification protocol."
  def subscribe_audio, do: HostOutput.subscribe_audio(__MODULE__, :legacy)

  @doc "Subscribe to both original NES notification protocols."
  def subscribe, do: HostOutput.subscribe(__MODULE__, :legacy)

  @doc "Subscribe to neutral `{:video_frame, :nes, number}` notifications."
  def subscribe_video_frames, do: HostOutput.subscribe_video(__MODULE__)

  @doc "Subscribe to neutral `{:audio_chunk, chunk}` notifications."
  def subscribe_audio_chunks, do: HostOutput.subscribe_audio(__MODULE__)

  @doc "The latest NES framebuffer, or nil when no frame has been published."
  def latest do
    case latest_video() do
      %VideoFrame{data: %Framebuffer{} = frame} -> frame
      nil -> nil
    end
  end

  @doc "The latest typed, system-neutral video envelope."
  def latest_video, do: HostOutput.latest_video_from_table(:nes_frames)

  @doc "Wrap an internal NES framebuffer for a system-neutral host."
  def video_frame(%Framebuffer{} = frame) do
    %VideoFrame{
      system: :nes,
      number: frame.number,
      width: frame.rgb_width || frame.width,
      height: frame.rgb_height || frame.height,
      pixel_format: {:native, :nes_framebuffer},
      data: frame,
      duration_ns: @period_ns
    }
  end
end
