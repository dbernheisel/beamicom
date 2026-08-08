defmodule Mix.Tasks.Beamicom.Stream do
  @shortdoc "Play a ROM through a local AV1/Opus RTP stream"
  @moduledoc """
  Starts a ROM, opens its generated SDP in ffplay, and reads terminal controls.

      mix beamicom.stream ROM [--host 127.0.0.1] [--port 5000]

  Use `--no-player` to skip launching ffplay or `--ffplay PATH` to select an
  alternative executable.
  """

  use Mix.Task

  alias Beamicom.TerminalInput
  alias Beamicom.EI.{Client, Server}
  alias BeamicomStream.{Player, SDP}

  @switches [
    host: :string,
    port: :integer,
    controller: :integer,
    no_player: :boolean,
    ffplay: :string,
    help: :boolean
  ]

  @impl true
  def run(argv) do
    case parse_args(argv) do
      {:ok, opts} -> run_session(opts)
      {:help, text} -> Mix.shell().info(text)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def parse_args(argv) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] -> {:help, usage()}
      invalid != [] -> {:error, "invalid options: #{inspect(invalid)}\n\n#{usage()}"}
      length(positional) != 1 -> {:error, usage()}
      opts[:controller] not in [nil, 1, 2] -> {:error, "--controller must be 1 or 2"}
      true -> build_options(hd(positional), opts)
    end
  end

  defp build_options(rom, opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 5_000)

    with {:ok, ip} <- parse_ipv4(host),
         true <- port in 1..65_533 do
      {:ok,
       %{
         rom: Path.expand(rom),
         host: ip,
         port: port,
         controller: Keyword.get(opts, :controller, 1),
         player?: not Keyword.get(opts, :no_player, false),
         ffplay: Keyword.get(opts, :ffplay, "ffplay")
       }}
    else
      false -> {:error, "--port must be between 1 and 65533"}
      {:error, _reason} -> {:error, "--host must be an IPv4 address"}
    end
  end

  defp run_session(opts) do
    Mix.Task.run("app.start")

    with :ok <- ensure_rom(opts.rom),
         {:ok, sdp} <- SDP.write_temp(opts.host, opts.port),
         {:ok, ffplay} <- start_ffplay(opts, sdp) do
      try do
        start_and_wait(opts, ffplay, sdp)
      after
        close_port(ffplay)
        File.rm(sdp)
      end
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  defp start_and_wait(opts, ffplay, sdp) do
    case Player.start_link(rom: opts.rom, target: {opts.host, opts.port}) do
      {:ok, player} ->
        Process.unlink(player)
        player_ref = Process.monitor(player)
        task = self()

        try do
          with {:ok, server} <-
                 Server.start_link(
                   path: Beamicom.EI.default_path(),
                   on_buttons: fn port, buttons -> Player.set_buttons(player, port, buttons) end
                 ),
               {:ok, client} <-
                 Client.start_link(
                   path: Beamicom.EI.default_path(),
                   name: "beamicom-stream-terminal"
                 ),
               :ok <- Client.await_ready(client),
               {:ok, input} <-
                 TerminalInput.start_link(
                   controller: opts.controller,
                   on_buttons: fn port, buttons -> Client.set_buttons(client, port, buttons) end,
                   on_quit: fn -> send(task, :quit) end
                 ) do
            Process.unlink(server)
            Process.unlink(client)
            Mix.shell().info("Streaming #{opts.rom}")
            Mix.shell().info("SDP: #{sdp} (video #{opts.port}, audio #{opts.port + 2})")
            Mix.shell().info("Arrows move; X=A, Z=B, Enter=Start, Space=Select, Q/Escape quits")

            try do
              run_terminal(input, ffplay, player_ref)
            after
              stop_process(input)
              stop_process(client)
              stop_process(server)
            end
          else
            {:error, reason} -> Mix.raise("could not start terminal input: #{inspect(reason)}")
          end
        after
          stop_process(player)
        end

      {:error, reason} ->
        Mix.raise(format_error(reason))
    end
  end

  defp run_terminal(input, ffplay, player_ref) do
    case TerminalInput.with_raw_terminal(fn device ->
           reader = Task.async(fn -> TerminalInput.read(input, device) end)

           try do
             await_session(reader, ffplay, player_ref)
           after
             Task.shutdown(reader, :brutal_kill)
           end
         end) do
      {:error, reason} -> Mix.raise("terminal input failed: #{inspect(reason)}")
      _result -> :ok
    end
  end

  defp await_session(reader, nil, player_ref) do
    receive do
      :quit ->
        :ok

      {ref, _result} when ref == reader.ref ->
        :ok

      {:DOWN, ref, :process, _pid, reason} when ref == reader.ref ->
        Mix.raise(inspect(reason))

      {:DOWN, ^player_ref, :process, _pid, reason} ->
        Mix.raise("stream stopped: #{inspect(reason)}")
    end
  end

  defp await_session(reader, ffplay, player_ref) when is_port(ffplay) do
    receive do
      :quit ->
        :ok

      {ref, _result} when ref == reader.ref ->
        :ok

      {:DOWN, ref, :process, _pid, reason} when ref == reader.ref ->
        Mix.raise(inspect(reason))

      {:DOWN, ^player_ref, :process, _pid, reason} ->
        Mix.raise("stream stopped: #{inspect(reason)}")

      {^ffplay, {:exit_status, 0}} ->
        :ok

      {^ffplay, {:exit_status, status}} ->
        Mix.raise("ffplay exited with status #{status}")

      {^ffplay, {:data, _data}} ->
        await_session(reader, ffplay, player_ref)
    end
  end

  defp start_ffplay(%{player?: false}, _sdp), do: {:ok, nil}

  defp start_ffplay(opts, sdp) do
    case System.find_executable(opts.ffplay) do
      nil ->
        {:error, {:missing_executable, opts.ffplay}}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              "-loglevel",
              "warning",
              "-protocol_whitelist",
              "file,udp,rtp",
              "-fflags",
              "nobuffer",
              "-flags",
              "low_delay",
              "-i",
              sdp
            ]
          ])

        {:ok, port}
    end
  end

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port),
    do: if(Port.info(port), do: Port.close(port), else: :ok)

  defp stop_process(pid) when is_pid(pid),
    do: if(Process.alive?(pid), do: GenServer.stop(pid), else: :ok)

  defp ensure_rom(path),
    do: if(File.regular?(path), do: :ok, else: {:error, {:rom_not_found, path}})

  defp parse_ipv4(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_error({:rom_not_found, path}), do: "ROM does not exist: #{path}"
  defp format_error({:missing_executable, name}), do: "executable not found: #{name}"
  defp format_error(reason), do: inspect(reason)

  defp usage do
    """
    Usage: mix beamicom.stream ROM [options]

      --host ADDRESS     local IPv4 destination (default: 127.0.0.1)
      --port PORT        video RTP port; audio uses PORT+2 (default: 5000)
      --controller 1|2   NES controller port (default: 1)
      --no-player        do not launch ffplay
      --ffplay PATH      ffplay executable override
    """
  end
end
