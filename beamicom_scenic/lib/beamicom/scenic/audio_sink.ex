defmodule Beamicom.Scenic.AudioSink do
  @moduledoc """
  System-aware audio sink for the Scenic host. It subscribes to either the NES
  compatibility output or a core-owned `Beamicom.Host.Output`, validates typed
  PCM chunks, and writes raw signed-16-bit little-endian audio to an external
  player. This supports NES mono plus Game Boy and SNES stereo without changing
  any emulator core. Audio uses a bounded latest-value subscription and
  non-blocking player writes so a slow device cannot turn an underrun into
  permanently delayed playback.

  At normal speed, macOS and Linux use a small SDL helper whose device queue is
  bounded by the device's consumed-byte clock. ffplay remains the fallback and
  handles pitch-preserving playback at non-default speeds. If the selected
  executable is unavailable, the sink quietly declines to start (`:ignore`) so
  video still works.

  ## Sources

    * SDL queued-audio playback; ffplay raw PCM fallback.
  """
  use GenServer
  require Logger

  alias Beamicom.Host.{AudioChunk, Output}
  alias Beamicom.NES.Output, as: NESOutput

  @default_audio %{sample_rate: 44_100, channels: 1, sample_format: :s16le}
  @demux_sample_rate 8_000
  @max_device_queue_ms 40

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  def set_volume(server \\ __MODULE__, volume),
    do: GenServer.call(server, {:set_volume, volume})

  @impl true
  def init(opts) do
    Process.flag(:priority, :high)

    output = Keyword.get(opts, :output, NESOutput)
    audio = Keyword.get(opts, :audio, @default_audio)
    volume = Keyword.get(opts, :volume, 100)
    command = Keyword.get(opts, :command, default_command(Keyword.get(opts, :speed, 1.0), audio))
    prebuffer_ms = Keyword.get(opts, :prebuffer_ms, 0)
    prebuffer_frames = max(0, div(audio.sample_rate * prebuffer_ms + 999, 1_000))

    case {command, volume} do
      {[exe | args], volume}
      when is_binary(exe) and is_integer(volume) and volume >= 0 and volume <= 100 ->
        start_player(exe, args, output, audio, prebuffer_frames, volume)

      {_command, volume} when not is_integer(volume) or volume < 0 or volume > 100 ->
        {:stop, {:invalid_volume, volume}}

      _invalid ->
        {:stop, {:invalid_audio_command, command}}
    end
  end

  defp start_player(executable, args, output, audio, prebuffer_frames, volume) do
    case System.find_executable(executable) do
      nil ->
        Logger.warning("#{inspect(__MODULE__)}: #{executable} not found; audio disabled")
        :ignore

      path ->
        port = open_player(path, args)
        :ok = subscribe(output)

        {:ok,
         %{
           port: port,
           executable: path,
           args: args,
           output: output,
           audio: audio,
           volume: volume,
           ready?: prebuffer_frames == 0,
           pending: [],
           pending_frames: 0,
           prebuffer_frames: prebuffer_frames
         }}
    end
  end

  @doc false
  def default_command(speed, audio \\ @default_audio, os \\ :os.type()) do
    case native_command(speed, audio, os) do
      nil -> ffplay_command(speed, audio)
      command -> command
    end
  end

  @doc false
  def ffplay_command(speed, audio \\ @default_audio) do
    layout = if audio.channels == 1, do: "mono", else: "stereo"

    # FFmpeg's raw PCM demuxer chooses packets at 10 Hz from its declared sample
    # rate. Declaring the real rate would make every read wait for roughly 100 ms
    # of samples before ffplay can hand anything to SDL. Use a low demux-only rate
    # to make those reads small, then restore the real rate without resampling or
    # changing pitch. asetpts gives the restored samples a continuous clock.
    ~w(ffplay -nodisp -autoexit -loglevel error -avioflags direct -fflags nobuffer -probesize 32 -analyzeduration 0 -f #{format(audio.sample_format)} -ar #{@demux_sample_rate} -ch_layout #{layout} -i pipe:0) ++
      audio_filters(speed, audio.sample_rate)
  end

  defp native_command(speed, audio, {:unix, os})
       when speed in [1, 1.0] and os in [:darwin, :linux] do
    path = Application.app_dir(:beamicom_scenic, "priv/native/audio_player")

    if File.regular?(path) do
      [
        path,
        Integer.to_string(audio.sample_rate),
        Integer.to_string(audio.channels),
        Integer.to_string(@max_device_queue_ms)
      ]
    end
  end

  defp native_command(_speed, _audio, _os), do: nil

  defp audio_filters(speed, sample_rate) do
    filters = ["asetrate=#{sample_rate}", "asetpts=N/SR/TB" | atempo_filters(speed)]
    ["-af", Enum.join(filters, ",")]
  end

  defp atempo_filters(speed) when speed == 1 or speed == 1.0, do: []

  # Individual atempo stages accept 0.5..100. Chain them so every positive
  # emulator speed has a matching, pitch-preserving audio consumption rate.
  defp atempo_filters(speed) when speed > 0,
    do: speed |> atempo_factors([]) |> Enum.map(&"atempo=#{&1}")

  defp atempo_factors(speed, factors) when speed < 0.5,
    do: atempo_factors(speed / 0.5, [0.5 | factors])

  defp atempo_factors(speed, factors) when speed > 100,
    do: atempo_factors(speed / 100, [100 | factors])

  defp atempo_factors(speed, factors), do: Enum.reverse([speed | factors])

  @impl true
  def handle_call(:pause, _from, %{port: nil} = state), do: {:reply, :ok, state}

  def handle_call(:pause, _from, state) do
    close_player(state.port)
    {:reply, :ok, reset_playback(state, nil)}
  end

  def handle_call(:resume, _from, %{port: port} = state) when is_port(port),
    do: {:reply, :ok, state}

  def handle_call(:resume, _from, state) do
    port = open_player(state.executable, state.args)
    {:reply, :ok, reset_playback(state, port)}
  end

  def handle_call({:set_volume, volume}, _from, state)
      when is_integer(volume) and volume >= 0 and volume <= 100,
      do: {:reply, :ok, %{state | volume: volume}}

  def handle_call({:set_volume, volume}, _from, state),
    do: {:reply, {:error, {:invalid_volume, volume}}, state}

  @impl true
  def handle_info({:audio_available, _system}, state) do
    case Output.latest_audio(state.output) do
      nil -> {:noreply, state}
      chunk -> handle_audio_chunk(chunk, state)
    end
  end

  def handle_info({:audio_chunk, %AudioChunk{}}, %{port: nil} = state),
    do: {:noreply, state}

  def handle_info({:audio_chunk, %AudioChunk{} = chunk}, state),
    do: handle_audio_chunk(chunk, state)

  def handle_info({:audio, _sample_count, _pcm}, %{port: nil} = state),
    do: {:noreply, state}

  def handle_info({:audio, sample_count, pcm}, %{ready?: false} = state),
    do: buffer_audio(state, pcm, sample_count, true, :audio_player_closed)

  def handle_info({:audio, _sample_count, pcm}, state) do
    write_audio(state, pcm, true, :audio_player_closed)
  end

  def handle_info({:frame, _number}, state), do: {:noreply, state}

  # The player exited (e.g. pipe closed or no audio device); shut down cleanly.
  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :normal, state}
  # Ignore video notifications and the player's own stdout.
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_audio_chunk(%AudioChunk{}, %{port: nil} = state), do: {:noreply, state}

  defp handle_audio_chunk(%AudioChunk{} = chunk, %{ready?: false} = state) do
    buffer_audio(
      state,
      chunk.data,
      chunk.frame_count,
      compatible?(chunk, state.audio),
      :invalid_audio_chunk
    )
  end

  defp handle_audio_chunk(%AudioChunk{} = chunk, state) do
    write_audio(state, chunk.data, compatible?(chunk, state.audio), :invalid_audio_chunk)
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    close_player(port)
    :ok
  end

  defp subscribe(output), do: Output.subscribe_latest_audio(output)

  defp open_player(executable, args),
    do:
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, {:parallelism, false}, args: args]
      )

  defp close_player(nil), do: :ok

  defp close_player(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp reset_playback(state, port) do
    %{
      state
      | port: port,
        ready?: state.prebuffer_frames == 0,
        pending: [],
        pending_frames: 0
    }
  end

  defp buffer_audio(state, pcm, frame_count, valid?, error) do
    state = %{
      state
      | pending: [pcm | state.pending],
        pending_frames: state.pending_frames + frame_count
    }

    cond do
      not valid? ->
        {:stop, error, state}

      state.pending_frames < state.prebuffer_frames ->
        {:noreply, state}

      true ->
        case command_audio(state, Enum.reverse(state.pending)) do
          {:ok, state} ->
            {:noreply, %{state | ready?: true, pending: [], pending_frames: 0}}

          {:error, state} ->
            {:stop, :audio_player_closed, state}
        end
    end
  end

  defp write_audio(state, _pcm, false, error), do: {:stop, error, state}

  defp write_audio(state, pcm, true, error) do
    case command_audio(state, pcm) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:stop, error, state}
    end
  end

  defp command_audio(state, pcm) do
    pcm = adjust_volume(pcm, state.volume)

    if Port.command(state.port, pcm, [:nosuspend]) do
      {:ok, state}
    else
      restart_player(state, pcm)
    end
  rescue
    ArgumentError -> restart_player(state, pcm)
  end

  defp restart_player(state, pcm) do
    close_player(state.port)
    port = open_player(state.executable, state.args)
    state = %{reset_playback(state, port) | ready?: true}

    if Port.command(port, pcm, [:nosuspend]), do: {:ok, state}, else: {:error, state}
  end

  defp adjust_volume(pcm, 100), do: pcm
  defp adjust_volume(pcm, volume), do: pcm |> IO.iodata_to_binary() |> scale_pcm(volume)

  @doc false
  def scale_pcm(pcm, volume)
      when is_binary(pcm) and is_integer(volume) and volume >= 0 and volume <= 100 do
    for <<sample::signed-little-16 <- pcm>>, into: <<>> do
      <<div(sample * volume, 100)::signed-little-16>>
    end
  end

  defp compatible?(chunk, audio) do
    chunk.sample_rate == audio.sample_rate and chunk.channels == audio.channels and
      chunk.sample_format == audio.sample_format and
      byte_size(chunk.data) == chunk.frame_count * chunk.channels * 2
  end

  defp format(:s16le), do: "s16le"
end
