defmodule Beamicom.NES.AudioSink do
  @moduledoc """
  Audio sink (spec §4): subscribes to `Beamicom.NES.Output` and pipes the APU's
  `{:audio, sample_count, pcm}` stream to `ffmpeg`'s CoreAudio (audiotoolbox)
  output as raw signed-16-bit LE mono PCM over an Erlang Port. The external
  player owns the CoreAudio stream and buffering, so the BEAM stays off the
  realtime audio path. audiotoolbox is used over `ffplay` because ffplay's
  ~46ms SDL audio buffer is fixed and dominates A/V lag; CoreAudio's buffer is
  much smaller.

  Requires `ffmpeg` (`brew install ffmpeg`); if it isn't found the sink quietly
  declines to start (`:ignore`) so video still works.

  ## Sources
    * ffmpeg `-f audiotoolbox` CoreAudio raw-PCM output.
  """
  use GenServer
  require Logger

  @rate 44_100

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    [exe | args] = Keyword.get(opts, :command, cmd_for(Keyword.get(opts, :speed, 1.0)))

    case System.find_executable(exe) do
      nil ->
        Logger.warning("Beamicom.NES.AudioSink: #{exe} not found; audio disabled")
        :ignore

      path ->
        port = Port.open({:spawn_executable, path}, [:binary, :exit_status, args: args])
        Beamicom.NES.Output.subscribe_audio()
        {:ok, %{port: port}}
    end
  end

  # Play the full-rate 44.1kHz stream via ffmpeg's CoreAudio (audiotoolbox) output
  # rather than ffplay: ffplay hardcodes an SDL audio buffer of ~2048 samples
  # (~46ms) with no flag to shrink it, which dominates A/V lag. audiotoolbox goes
  # straight to CoreAudio with a much smaller buffer, so audio tracks video closely.
  # `speed` is applied with the pitch-preserving `atempo` filter (0.5× consumes
  # 22050 input samples/sec — exactly what the Runtime produces when paced to 0.5×).
  defp cmd_for(speed) do
    ~w(ffmpeg -loglevel quiet -f s16le -ar #{@rate} -ch_layout mono -i -) ++
      atempo(speed) ++ ~w(-f audiotoolbox -)
  end

  # `atempo` only accepts 0.5..100.0, so factors below 0.5 must be chained
  # (0.5 * (speed/0.5) = speed). Handles down to 0.25 with two stages.
  defp atempo(speed) when speed >= 1.0, do: []
  defp atempo(speed) when speed >= 0.5, do: ["-af", "atempo=#{speed}"]
  defp atempo(speed), do: ["-af", "atempo=0.5,atempo=#{speed / 0.5}"]

  @impl true
  def handle_info({:audio, _sample_count, pcm}, state) do
    Port.command(state.port, pcm)
    {:noreply, state}
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
end
