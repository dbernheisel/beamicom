defmodule Beamicom.NES.Output do
  @moduledoc """
  Decoupled A/V fan-out (spec §4, §6.1). The core produces one
  `%Beamicom.NES.Framebuffer{}` per PPU frame and `publish/1`es it here; sinks (Scenic,
  Phoenix channel, GStreamer feed) `subscribe/0` for `{:frame, number}`
  notifications and read the latest frame from ETS when ready. APU audio is
  streamed separately via `publish_audio/1` → `{:audio, samples}` (no coalescing —
  audio can't drop samples).

  Owns a `:read_concurrency` ETS table so reads bypass the GenServer entirely —
  the publish cost is one ETS insert plus an async notify, and it never blocks
  the emulation core. A slow sink simply reads the newest frame and drops the
  intermediates; no queueing policy (automatic coalescing).

  ## Sources
    * NESdev / spec §6.1 — ETS latest-frame + notify, no pixel copies on publish.
  """
  use GenServer

  @table :nes_frames

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Publish a video frame (fire-and-forget): ETS insert + async notify."
  def publish(frame), do: GenServer.cast(__MODULE__, {:publish, frame})

  @doc """
  Publish a chunk of APU audio samples. Unlike video (latest-frame, coalesced),
  audio is a stream: every chunk is pushed to subscribers as `{:audio, samples}`
  so a sink can feed a sound device without gaps.
  """
  def publish_audio([]), do: :ok
  def publish_audio(samples), do: GenServer.cast(__MODULE__, {:audio, samples})

  @doc """
  Subscribe the caller to video `{:frame, number}` notifications only. A
  video-only sink (the Scenic screen) never receives — and never has copied into
  its mailbox — the audio sample chunks it would just ignore.
  """
  def subscribe_video, do: GenServer.call(__MODULE__, {:subscribe, :video})

  @doc "Subscribe the caller to audio `{:audio, samples}` chunks only (the audio sink)."
  def subscribe_audio, do: GenServer.call(__MODULE__, {:subscribe, :audio})

  @doc "Subscribe the caller to both video and audio (e.g. a combined sink or test)."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, :both})

  @doc "The latest published frame, read straight from ETS (nil if none yet)."
  def latest do
    case :ets.lookup(@table, :latest) do
      [{:latest, frame}] -> frame
      [] -> nil
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{video: MapSet.new(), audio: MapSet.new()}}
  end

  @impl true
  def handle_call({:subscribe, kind}, {pid, _}, state) do
    Process.monitor(pid)
    video = if kind in [:video, :both], do: MapSet.put(state.video, pid), else: state.video
    audio = if kind in [:audio, :both], do: MapSet.put(state.audio, pid), else: state.audio
    {:reply, :ok, %{state | video: video, audio: audio}}
  end

  @impl true
  def handle_cast({:publish, frame}, state) do
    :ets.insert(@table, {:latest, frame})
    Enum.each(state.video, &send(&1, {:frame, frame.number}))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:audio, samples}, state) do
    Enum.each(state.audio, &send(&1, {:audio, samples}))
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do:
      {:noreply,
       %{state | video: MapSet.delete(state.video, pid), audio: MapSet.delete(state.audio, pid)}}
end
