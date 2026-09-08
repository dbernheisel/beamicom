defmodule Beamicom.NES.AudioSink do
  @moduledoc """
  System-aware audio sink for the Scenic host. It subscribes to either the NES
  compatibility output or a core-owned `Beamicom.Host.Output`, validates typed
  PCM chunks, and writes raw signed-16-bit little-endian audio to an external
  player. This supports NES mono and Game Boy stereo without changing either
  emulator core.

  On macOS the existing low-latency CoreAudio path is retained through ffmpeg;
  other platforms use ffplay. If the selected executable is unavailable, the
  sink quietly declines to start (`:ignore`) so video still works.

  ## Sources
    * ffmpeg raw PCM input and CoreAudio output; ffplay elsewhere.
  """
  use GenServer
  require Logger

  alias Beamicom.Host.{AudioChunk, Output}
  alias Beamicom.NES.Output, as: NESOutput

  @default_audio %{sample_rate: 44_100, channels: 1, sample_format: :s16le}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    output = Keyword.get(opts, :output, NESOutput)
    audio = Keyword.get(opts, :audio, @default_audio)
    command = Keyword.get(opts, :command, default_command(Keyword.get(opts, :speed, 1.0), audio))

    case command do
      [exe | args] when is_binary(exe) ->
        start_player(exe, args, output, audio)

      _invalid ->
        {:stop, {:invalid_audio_command, command}}
    end
  end

  defp start_player(executable, args, output, audio) do
    case System.find_executable(executable) do
      nil ->
        Logger.warning("Beamicom.NES.AudioSink: #{executable} not found; audio disabled")
        :ignore

      path ->
        port = Port.open({:spawn_executable, path}, [:binary, :exit_status, args: args])
        :ok = subscribe(output)
        {:ok, %{port: port, audio: audio}}
    end
  end

  @doc false
  def default_command(speed, audio \\ @default_audio, os \\ :os.type()) do
    layout = if audio.channels == 1, do: "mono", else: "stereo"

    case os do
      {:unix, :darwin} ->
        ~w(ffmpeg -loglevel quiet -fflags nobuffer -probesize 32 -analyzeduration 0 -f #{format(audio.sample_format)} -ar #{audio.sample_rate} -ch_layout #{layout} -i -) ++
          atempo(speed) ++ ~w(-f audiotoolbox -)

      _other ->
        ~w(ffplay -nodisp -autoexit -loglevel error -fflags nobuffer -probesize 32 -analyzeduration 0 -f #{format(audio.sample_format)} -ar #{audio.sample_rate} -ch_layout #{layout} -i pipe:0) ++
          atempo(speed)
    end
  end

  defp atempo(speed) when speed == 1 or speed == 1.0, do: []

  # Individual atempo stages accept 0.5..100. Chain them so every positive
  # emulator speed has a matching, pitch-preserving audio consumption rate.
  defp atempo(speed) when speed > 0 do
    filter = speed |> atempo_factors([]) |> Enum.map_join(",", &"atempo=#{&1}")
    ["-af", filter]
  end

  defp atempo_factors(speed, factors) when speed < 0.5,
    do: atempo_factors(speed / 0.5, [0.5 | factors])

  defp atempo_factors(speed, factors) when speed > 100,
    do: atempo_factors(speed / 100, [100 | factors])

  defp atempo_factors(speed, factors), do: Enum.reverse([speed | factors])

  @impl true
  def handle_info({:audio_chunk, %AudioChunk{} = chunk}, state) do
    if compatible?(chunk, state.audio) and Port.command(state.port, chunk.data) do
      {:noreply, state}
    else
      {:stop, :invalid_audio_chunk, state}
    end
  end

  def handle_info({:audio, _sample_count, pcm}, state) do
    if Port.command(state.port, pcm),
      do: {:noreply, state},
      else: {:stop, :audio_player_closed, state}
  end

  def handle_info({:frame, _}, state) do
    {:noreply, state}
  end

  # The player exited (e.g. pipe closed or no audio device); shut down cleanly.
  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :normal, state}
  # Ignore video notifications and the player's own stdout.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp subscribe(NESOutput), do: NESOutput.subscribe_audio_chunks()
  defp subscribe(output), do: Output.subscribe_audio(output)

  defp compatible?(chunk, audio) do
    chunk.sample_rate == audio.sample_rate and chunk.channels == audio.channels and
      chunk.sample_format == audio.sample_format and
      byte_size(chunk.data) == chunk.frame_count * chunk.channels * 2
  end

  defp format(:s16le), do: "s16le"
end
