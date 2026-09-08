defmodule Beamicom.Host.Output do
  @moduledoc """
  Non-blocking audio/video fan-out shared by emulator cores.

  Video is coalesced: each subscriber has at most one notification outstanding
  and asks for the latest frame when it handles that notification. Reading the
  frame acknowledges the notification so a later publish can wake the
  subscriber again. Audio is lossless and every chunk is delivered. The
  `:legacy` notification option exists for adapters that are preserving an
  older client protocol during migration.
  """

  use GenServer

  alias Beamicom.Host.{AudioChunk, VideoFrame}

  @type notification :: :envelope | :legacy

  def child_spec(opts) do
    name = Keyword.get(opts, :name)
    id = if is_nil(name), do: __MODULE__, else: {__MODULE__, name}

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @spec publish_video(GenServer.server(), VideoFrame.t()) :: :ok
  def publish_video(server, %VideoFrame{} = frame),
    do: GenServer.cast(server, {:publish_video, frame})

  @spec publish_audio(GenServer.server(), AudioChunk.t()) :: :ok
  def publish_audio(_server, %AudioChunk{frame_count: 0, data: <<>>}), do: :ok

  def publish_audio(server, %AudioChunk{} = chunk),
    do: GenServer.cast(server, {:publish_audio, chunk})

  @spec subscribe_video(GenServer.server(), notification()) :: :ok
  def subscribe_video(server, notification \\ :envelope),
    do: GenServer.call(server, {:subscribe, :video, notification})

  @spec subscribe_audio(GenServer.server(), notification()) :: :ok
  def subscribe_audio(server, notification \\ :envelope),
    do: GenServer.call(server, {:subscribe, :audio, notification})

  @spec subscribe(GenServer.server(), notification()) :: :ok
  def subscribe(server, notification \\ :envelope),
    do: GenServer.call(server, {:subscribe, :both, notification})

  @doc "Read the latest frame and acknowledge the caller's pending notification."
  @spec latest_video(GenServer.server()) :: VideoFrame.t() | nil
  def latest_video(server), do: GenServer.call(server, :latest_video)

  @doc "Read and acknowledge the latest frame directly through a public ETS table."
  @spec latest_video_from_table(atom()) :: VideoFrame.t() | nil
  def latest_video_from_table(table) when is_atom(table) do
    # Clearing the marker before reading closes the race with a concurrent
    # publish: that publish either happens first and is included in this read,
    # or happens afterwards and sends a fresh notification.
    :ets.delete(table, {:video_notification, self()})

    case :ets.lookup(table, :latest_video) do
      [{:latest_video, frame}] -> frame
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    table =
      case Keyword.get(opts, :table) do
        nil -> nil
        name -> :ets.new(name, [:named_table, :public, read_concurrency: true])
      end

    {:ok,
     %{
       latest_video: nil,
       table: table,
       video: %{},
       audio: %{},
       video_notifications: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:latest_video, {pid, _tag}, state) do
    {:reply, state.latest_video, acknowledge_video(state, pid)}
  end

  def handle_call({:subscribe, kind, notification}, {pid, _tag}, state)
      when kind in [:video, :audio, :both] and notification in [:envelope, :legacy] do
    unless Map.has_key?(state.video, pid) or Map.has_key?(state.audio, pid),
      do: Process.monitor(pid)

    video =
      if kind in [:video, :both], do: Map.put(state.video, pid, notification), else: state.video

    audio =
      if kind in [:audio, :both], do: Map.put(state.audio, pid, notification), else: state.audio

    {:reply, :ok, %{state | video: video, audio: audio}}
  end

  @impl true
  def handle_cast({:publish_video, frame}, state) do
    if state.table, do: :ets.insert(state.table, {:latest_video, frame})

    state = Enum.reduce(state.video, state, &notify_video(&1, frame, &2))

    {:noreply, %{state | latest_video: frame}}
  end

  def handle_cast({:publish_audio, chunk}, state) do
    Enum.each(state.audio, fn {pid, notification} ->
      case notification do
        :envelope -> send(pid, {:audio_chunk, chunk})
        :legacy -> send(pid, {:audio, chunk.frame_count, chunk.data})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if state.table, do: :ets.delete(state.table, {:video_notification, pid})

    {:noreply,
     %{
       state
       | video: Map.delete(state.video, pid),
         audio: Map.delete(state.audio, pid),
         video_notifications: MapSet.delete(state.video_notifications, pid)
     }}
  end

  defp notify_video({pid, notification}, frame, %{table: nil} = state) do
    if MapSet.member?(state.video_notifications, pid) do
      state
    else
      send_video_notification(pid, notification, frame)
      %{state | video_notifications: MapSet.put(state.video_notifications, pid)}
    end
  end

  defp notify_video({pid, notification}, frame, state) do
    if :ets.insert_new(state.table, {{:video_notification, pid}, true}),
      do: send_video_notification(pid, notification, frame)

    state
  end

  defp send_video_notification(pid, :envelope, frame),
    do: send(pid, {:video_frame, frame.system, frame.number})

  defp send_video_notification(pid, :legacy, frame), do: send(pid, {:frame, frame.number})

  defp acknowledge_video(%{table: nil} = state, pid) do
    %{state | video_notifications: MapSet.delete(state.video_notifications, pid)}
  end

  defp acknowledge_video(state, pid) do
    :ets.delete(state.table, {:video_notification, pid})
    state
  end
end
