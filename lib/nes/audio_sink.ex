defmodule Beamicom.NES.AudioSink do
  @moduledoc """
  Audio sink (spec §4): subscribes to `Beamicom.NES.Output` and pipes the APU's
  `{:audio, samples}` stream to `ffplay` as raw signed-16-bit LE mono PCM over an
  Erlang Port. The external player owns the CoreAudio stream and buffering, so
  the BEAM stays off the realtime audio path.

  Requires `ffplay` (`brew install ffmpeg`); if it isn't found the sink quietly
  declines to start (`:ignore`) so video still works.

  ## Sources
    * ffmpeg `ffplay -f s16le` raw-PCM stdin playback.
  """
  use GenServer
  require Logger

  @rate 44_100

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Encode signed-16-bit sample integers to little-endian PCM bytes."
  def pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::signed-little-16>>)

  @impl true
  def init(opts) do
    [exe | args] = Keyword.get(opts, :command, cmd_for(Keyword.get(opts, :rate, @rate)))

    case System.find_executable(exe) do
      nil ->
        Logger.warning("Beamicom.NES.AudioSink: #{exe} not found; audio disabled")
        :ignore

      path ->
        port = Port.open({:spawn_executable, path}, [:binary, :exit_status, args: args])
        Beamicom.NES.Output.subscribe()
        {:ok, %{port: port}}
    end
  end

  defp cmd_for(rate),
    do: ~w(ffplay -nodisp -autoexit -loglevel quiet -f s16le -ar #{rate} -ch_layout mono -i -)

  @impl true
  def handle_info({:audio, samples}, state) do
    Port.command(state.port, pcm(samples))
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
