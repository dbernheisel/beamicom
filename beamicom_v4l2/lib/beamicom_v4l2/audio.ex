defmodule BeamicomV4L2.Audio do
  @moduledoc """
  Plays Beamicom's signed 16-bit mono PCM stream through an external player.

  The default player is `ffplay`. A custom command can be supplied for tests or
  for routing audio into a system-specific sink.
  """

  use GenServer
  require Logger

  @rate 44_100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name)

    if name do
      GenServer.start_link(__MODULE__, options, name: name)
    else
      GenServer.start_link(__MODULE__, options)
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    command = Keyword.get(options, :command, default_command(Keyword.get(options, :speed, 1.0)))

    with [executable | arguments] when is_binary(executable) <- command,
         path when is_binary(path) <- System.find_executable(executable) do
      port =
        Port.open(
          {:spawn_executable, path},
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: arguments]
        )

      :ok = Beamicom.NES.Output.subscribe_audio()
      {:ok, %{port: port, executable: executable, chunks: 0, samples: 0, log: ""}}
    else
      [] -> {:stop, {:invalid_audio_command, command}}
      nil -> {:stop, {:audio_executable_not_found, List.first(command)}}
      _other -> {:stop, {:invalid_audio_command, command}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running: true, chunks: state.chunks, samples: state.samples}, state}
  end

  @impl true
  def handle_info({:audio, sample_count, pcm}, state)
      when is_integer(sample_count) and is_binary(pcm) do
    if Port.command(state.port, pcm) do
      {:noreply, %{state | chunks: state.chunks + 1, samples: state.samples + sample_count}}
    else
      {:stop, :audio_player_closed, state}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | log: tail(state.log <> data)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0 do
      Logger.warning(
        "Beamicom audio player #{state.executable} exited with status #{status}: #{state.log}"
      )
    end

    {:stop, {:audio_player_exit, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp default_command(speed) do
    ~w(ffplay -nodisp -autoexit -loglevel error -fflags nobuffer -probesize 32 -analyzeduration 0 -f s16le -ar #{@rate} -ac 1 -i pipe:0) ++
      atempo(speed)
  end

  defp atempo(speed) when speed >= 1.0, do: []
  defp atempo(speed) when speed >= 0.5, do: ["-af", "atempo=#{speed}"]
  defp atempo(speed), do: ["-af", "atempo=0.5,atempo=#{speed / 0.5}"]

  defp tail(log) when byte_size(log) <= 4_096, do: log
  defp tail(log), do: binary_part(log, byte_size(log) - 4_096, 4_096)
end
